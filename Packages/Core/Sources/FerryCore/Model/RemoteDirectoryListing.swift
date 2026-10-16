import Foundation

/// 一次目录列表的产物，加上**这张清单自带的软链解析缓存**。
///
/// 缓存放在清单上而不是放在连接里，理由是两个实测数：单条软链走完整条链要
/// 4–11 次网络往返（M0b-01 §0 结论 7），而 readdir 摊下来 0.019 RTT/条目
/// （M0b-04：1000 条 28.9 ms vs 逐条 stat 366.9 ms）。所以 ADR-0001 D8 定的是
/// "清单一行取完、比对在本地做，禁止逐条 stat"，链的解析也只能"这一批里走过的段不再走第二遍"。
/// 挂在连接上会出问题：重新列目录之后远端的链可能已经改指别处，
/// 旧缓存让同步引擎拿"上一次解析出来的路径"去比对现在的内容。
public struct RemoteDirectoryListing: Sendable, Hashable {
    /// 一条软链的解析结果。
    public struct LinkResolution: Sendable, Hashable {
        /// `readlink` 拿到的原文，**未解析**：相对目标就是相对目标。
        /// nil = 这一次没能从服务器读到目标。
        public let target: RemotePath?
        /// 整条链展开之后的绝对路径，语义与服务器 `realpath` 对齐（M0b-01 §1）。
        /// 断链照样有值：目标不存在不等于目标不知道（`broken` → `…/nowhere` 那格，
        /// 服务器 realpath 与词法解析逐字一致）。成环时为 nil。
        public let resolved: RemotePath?
        /// 这次解析向服务器查了几段。缓存命中是 0——
        /// 这个数就是"缓存到底省下多少往返"的度量口径（M1-05 §4）。
        public let segmentsLookedUp: Int

        public init(target: RemotePath?, resolved: RemotePath?, segmentsLookedUp: Int) {
            self.target = target
            self.resolved = resolved
            self.segmentsLookedUp = segmentsLookedUp
        }
    }

    /// 已按 `PathResolver.lexicalResolve` 解析过的绝对路径，也是所有条目路径的父。
    public let directory: RemotePath
    public let entries: [RemoteItem]
    /// 问过 `readlink` 的路径 → 直接目标；nil 表示"这段不是软链"（含不存在）。
    ///
    /// 键既可能是清单里的条目，也可能是解析链时路过的**中间段**，省下往返的正是后者：
    /// 迷宫里 8 条链都经过 `dir1`，第一次之后那段就是缓存命中。
    public private(set) var probes: [RemotePath: RemotePath?]
    /// 按条目路径存好的最终结果。
    public private(set) var resolutions: [RemotePath: LinkResolution]

    public init(directory: RemotePath, entries: [RemoteItem], probes: [RemotePath: RemotePath?] = [:],
                resolutions: [RemotePath: LinkResolution] = [:]) {
        self.directory = directory
        self.entries = entries
        self.probes = probes
        self.resolutions = resolutions
    }

    public func resolution(for item: RemoteItem) -> LinkResolution? {
        resolutions[item.path]
    }

    /// 记下一次 `readlink` 的结果。解析循环每查一段就写一次，
    /// 于是同一条链的第二遍、以及别的链路过同一段时都是 0 次往返。
    public mutating func noteProbe(_ path: RemotePath, target: RemotePath?) {
        probes[path] = target
    }

    /// 这段路径问过没有。区分"没问过"与"问过、答案是它不是链"，
    /// 否则缓存里那条 nil 会被当成 miss 而再问一次服务器。
    public func hasProbe(for path: RemotePath) -> Bool { probes[path] != nil }

    public func probedTarget(for path: RemotePath) -> RemotePath? { probes[path] ?? nil }

    public mutating func note(_ resolution: LinkResolution, for item: RemoteItem) {
        resolutions[item.path] = resolution
    }

    /// 已经解析过、但链本身已经不在清单里的条目数。
    ///
    /// 留着它是因为"重新列一次"之后缓存要能作废：这份数不为 0 就说明缓存里有
    /// 上一次清单的条目，调用方该知道（M1-05 §4.3）。
    public var staleResolutionCount: Int {
        let live = Set(entries.map(\.path))
        return resolutions.keys.filter { !live.contains($0) }.count
    }

    /// 同一绝对路径在一张清单里出现两次以上。
    ///
    /// 比较键碰撞之外还有这一种撞名：服务器不该给，但拿到了必须被发现——
    /// 静默覆盖是同步引擎最坏的失效方式。同一条路径重复三遍也只列一次：
    /// 这里要回答的是"哪些名字撞了"，不是"撞了几手"。
    public var duplicatePaths: [RemotePath] {
        var seen = Set<RemotePath>()
        var reported = Set<RemotePath>()
        var repeated = [RemotePath]()
        for item in entries {
            guard !seen.insert(item.path).inserted,
                  reported.insert(item.path).inserted else { continue }
            repeated.append(item.path)
        }
        return repeated
    }
}
