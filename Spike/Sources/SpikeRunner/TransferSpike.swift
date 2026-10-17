import CLibssh2
import CryptoKit
import Darwin
import FerryBackendsSFTP
import FerryCore
import Foundation

/// M1'-6 用：单文件上下传这一层的**原始事实**（正式路径那一半）。
///
/// 另一半在 `TransferRawSpike`（裸 C），那里复现四件只在 libssh2 内部发生、
/// 正式路径已经绕开的事：`fsync` 扩展支持面、不排空就关闭会不会截断文件、
/// `FXF_TRUNC` 到底防住了什么、半途放弃一次 READ 之后对面还认不认这条通道。
///
/// 用法（五台要先起着，语料要铺过）：
///   Spike/Scripts/seed-transfer-corpus.sh
///   Spike/.build/debug/SpikeRunner transfer
///   SPIKE_PORTS="2202" SPIKE_CHUNKS="65536,262144" …/SpikeRunner transfer
enum TransferSpike {
    private static let goodPassword = "testpass"
    private static let ports: [Int] = (ProcessInfo.processInfo.environment["SPIKE_PORTS"]
                                         ?? "2201 2202 2203 2204 2205")
        .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Int($0) }
    private static let host = ProcessInfo.processInfo.environment["SPIKE_HOST"] ?? "127.0.0.1"
    private static let chunks: [Int] = (ProcessInfo.processInfo.environment["SPIKE_CHUNKS"]
                                          ?? "65536,262144,1048576")
        .split(separator: ",").compactMap { Int($0) }
    private static let megabytes = 16

    // MARK: - 小工具

    private struct PassTrust: HostKeyTrust {
        func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws {}
    }

    /// 进度回调的记账。`onUpdate` 是 `@Sendable` 的，不能就地改一个局部 `var`，
    /// 而且节流生不生效看的正是"两次回调之间的最小间隔"，所以要留时间戳。
    private final class Tally: @unchecked Sendable {
        private(set) var count = 0
        private var previous: Date?
        private var smallest: Double = .greatestFiniteMagnitude

        func hit() {
            let now = Date()
            if let previous { smallest = Swift.min(smallest, now.timeIntervalSince(previous) * 1000) }
            previous = now
            count += 1
        }

        /// 不足两次回调时回 -1：那种情况下"间隔"这个数没有意义。
        var minGapMs: Double { count < 2 ? -1 : smallest }
    }

    private static func makeConnection(port: Int) -> SFTPConnection {
        SFTPConnection(request: ConnectionRequest(
            endpoint: Endpoint(host: host, port: port, username: "tester"),
            authentication: .password(goodPassword),
            policy: ConnectionPolicy(connectTimeout: .seconds(10), handshakeTimeout: .seconds(60),
                                     authenticationTimeout: .seconds(30),
                                     algorithms: HandshakeProbe.legacy)),
            hostKeyTrust: PassTrust())
    }

    /// 语料在容器里恒为 `/home/tester/spike/…`，但 2201 是 chroot，客户端看到的根是 `/`。
    /// 所以基准只能问服务器，再逐段拼（M0b-01 §0.3）。
    private static func inHome(_ home: RemotePath, _ suffix: String) -> RemotePath? {
        var current = home
        for component in suffix.split(separator: "/") {
            guard let next = try? PathResolver.child(of: current, name: Array(component.utf8))
            else { return nil }
            current = next
        }
        return current
    }

    private static func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    private static func msSince(_ date: Date) -> Double {
        Date().timeIntervalSince(date) * 1000
    }

    private static func token(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let remote = error as? RemoteError { return remote.diagnosticCode }
        return "other(\(error))"
    }

    /// 本地负载文件：16 MB 真随机，只造一次，五台共用。
    ///
    /// 不能用全零：这一轮的验收全是字节级的，而"整块漏发""块序错乱"这类 bug 在
    /// 全零内容上完全看不出来。随机内容 + 服务器侧 `sha256sum` 留下的那份哈希，
    /// 才是独立于 Swift 的参照物。
    private static func localSource(megabytes mb: Int = megabytes) -> URL {
        let url = tempURL("ferry-xfer-\(mb)m.bin")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attributes[.size] as? Int) == mb * 1_048_576 { return url }
        if let random = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom")),
           let data = try? random.read(upToCount: mb * 1_048_576) {
            try? data.write(to: url)
            try? random.close()
        }
        return url
    }

    /// 按 256 KB 分块流式算，不把 16 MB 整个读进内存。
    private static func sha256Hex(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "<读不到>" }
        var digest = SHA256()
        while true {
            let data = (try? handle.read(upToCount: 262_144)) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        try? handle.close()
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 入口

    static func run() async {
        print("libssh2 \(SpikeProbe.version())，服务器 = \(ports.map(String.init).joined(separator: " "))")
        let source = localSource()
        print("本地源 \(source.lastPathComponent) 16 MB sha=\(sha256Hex(of: source).prefix(16))…")
        print(String(format: "本地图层：造 16 MB %.1f ms，分块读 16 MB %.1f ms（同步 FileHandle，每 chunk 256 KB）",
                     localWriteMs(), localReadMs(url: source)))

        for port in ports {
            print("\n===== \(port) =====")
            await oneServer(port: port, source: source)
        }
        print("""

            结论与表格见 docs/spike/M1-06。语料：Spike/Scripts/seed-transfer-corpus.sh
        """)
    }

    private static func oneServer(port: Int, source: URL) async {
        let connection = makeConnection(port: port)
        do {
            _ = try await connection.handshake()
            _ = try await connection.authenticate(interactive: nil)
        } catch {
            print("  认证失败：\(token(error))  phase=\(await connection.phase)")
            return
        }
        guard let home = try? await connection.homeDirectory() else {
            print("  realpath(\".\") 失败，后面跑不了")
            return
        }
        guard let remote = inHome(home, "spike/xfer/mid16m.bin"),
              let midSidecar = inHome(home, "spike/xfer/mid16m.bin.sha256"),
              let sidecar = inHome(home, "spike/xfer/rand4m.bin.sha256"),
              let rand4m = inHome(home, "spike/xfer/rand4m.bin") else {
            print("  语料路径映射不出来"); return
        }
        let remoteExpectedHash = await downloadHash(sidecar: midSidecar, connection: connection)

        // ① 下载：逐 chunk 档位，报吞吐与 libssh2 那侧的调用计数
        print("  ① 下载（远端 16 MB → 本地）")
        for chunk in chunks {
            let target = tempURL("ferry-dl-\(port)-\(chunk).bin")
            let tally = Tally()
            let before = await connection.measure
            let started = Date()
            do {
                let bytes = try await TransferEngine.download(remote, to: target, using: connection,
                                                              chunkBytes: chunk,
                                                              onUpdate: { _ in tally.hit() })
                let elapsed = msSince(started)
                let after = await connection.measure
                print(String(format: "     chunk=%-8d bytes=%d  %7.1f ms  %6.1f MB/s  read调用=%d  "
                                  + "进度回调=%d 最小间隔=%.1f ms  C侧净时=%d ms",
                             chunk, bytes, elapsed, Double(bytes) / 1_048_576.0 / (elapsed / 1000.0),
                             after.file.readChunks - before.file.readChunks, tally.count, tally.minGapMs,
                             after.file.transferElapsedMs - before.file.transferElapsedMs))
                // 传完就地验字节：只比大小抓不到"块数对了但内容错位"。
                let local = sha256Hex(of: target)
                if let expected = remoteExpectedHash, local != expected {
                    print("     ↓ sha 不一致：\(local.prefix(16))… ≠ \(expected.prefix(16))…")
                }
            } catch {
                print("     chunk=\(chunk) 失败：\(token(error))  phase=\(await connection.phase)")
                await connection.close()
                return
            }
            try? FileManager.default.removeItem(at: target)
        }

        // ② 上传：同档位，重点看 writeChunks 与 writeCredits 之比（= 一个 chunk 要几轮才确认完）
        print("  ② 上传（本地 16 MB → 远端）")
        for chunk in chunks {
            guard let target = inHome(home, "spike/xfer/up-\(port)-\(chunk).bin") else { continue }
            let tally = Tally()
            let before = await connection.measure
            let started = Date()
            do {
                let bytes = try await TransferEngine.upload(from: source, to: target, using: connection,
                                                            chunkBytes: chunk,
                                                            onUpdate: { _ in tally.hit() })
                let elapsed = msSince(started)
                let after = await connection.measure
                let calls = after.file.writeChunks - before.file.writeChunks
                let credits = after.file.writeCredits - before.file.writeCredits
                print(String(format: "     chunk=%-8d bytes=%d  %7.1f ms  %6.1f MB/s  write调用=%d "
                                  + "确认轮=%d 每chunk %.2f 轮  进度回调=%d 最小间隔=%.1f ms",
                             chunk, bytes, elapsed, Double(bytes) / 1_048_576.0 / (elapsed / 1000.0),
                             calls, credits, Double(credits) / Double(max(calls, 1)), tally.count,
                             tally.minGapMs))
                let remoteSize = await size(of: target, connection: connection)
                if remoteSize != Int(bytes) {
                    print("     ↓ 远端 \(remoteSize) 字节 ≠ write 返回的 \(bytes) 字节")
                }
            } catch {
                print("     chunk=\(chunk) 失败：\(token(error))  phase=\(await connection.phase)")
                await connection.close()
                return
            }
        }

        // 覆盖：用 4 MB 盖掉刚才那份 16 MB。尾巴没清就是静默损坏（FXF_TRUNC 那条依据）。
        if let overwritten = inHome(home, "spike/xfer/up-\(port)-\(chunks.first ?? 0).bin") {
            let longSize = await size(of: overwritten, connection: connection)
            do {
                _ = try await TransferEngine.upload(from: localSource(megabytes: 4), to: overwritten,
                                                     using: connection)
                let afterSize = await size(of: overwritten, connection: connection)
                print("     短文件覆盖长文件：\(longSize) → \(afterSize) 字节  "
                      + (afterSize == 4_194_304 ? "截断生效" : "尾巴没清！"))
            } catch {
                print("     覆盖失败：\(token(error))")
            }
        }

        // ③ 参照哈希：先下 `.sha256` 再下正文。参照物由服务器侧 coreutils 算出，
        //    与 Swift 侧的 CryptoKit 无关，两边对上才算数。
        let reference = await downloadHash(sidecar: sidecar, connection: connection)
        let refTarget = tempURL("ferry-ref-\(port).bin")
        do {
            let bytes = try await TransferEngine.download(rand4m, to: refTarget, using: connection)
            let local = sha256Hex(of: refTarget)
            let verdict = reference == nil ? "（无参照）" : (reference == local ? "一致" : "不一致")
            print("  ③ 参照校验：rand4m.bin \(bytes) 字节  本地 \(local.prefix(16))…  "
                  + "语料 \(reference?.prefix(16) ?? "<无>")…  \(verdict)")
        } catch {
            print("  ③ 参照校验失败：\(token(error))")
        }
        try? FileManager.default.removeItem(at: refTarget)

        // ④ 传输途中插 list()：chunk 之间是不是真空得出来（第二个在途请求回 -31 那条）
        await interleaveProbe(remote: remote, home: home, connection: connection)

        // ⑤ 小文件与空文件：EOF 判定与"一次都没读"的路径
        let edges: [(String, Int)] = [("spike/xfer/small.txt", 12), ("spike/xfer/empty.bin", 0),
                                      ("spike/xfer/one256k.bin", 262_144),
                                      ("spike/xfer/odd30001.bin", 30_001)]
        print("  ⑤ 边界（小 / 空 / 整块 / 跨一个包边界 30001）")
        for (suffix, want) in edges {
            guard let edge = inHome(home, suffix) else { continue }
            let name = (suffix as NSString).lastPathComponent
            let edgeTarget = tempURL("ferry-edge-\(port)-\(name)")
            do {
                let got = try await TransferEngine.download(edge, to: edgeTarget, using: connection)
                print("     \(name) 下回 \(got) 字节，语料 \(want) 字节" + (got == want ? "" : " ← 不符"))
            } catch {
                print("     \(name) 失败：\(token(error))")
            }
            try? FileManager.default.removeItem(at: edgeTarget)
        }

        // ⑥ 取消：K1 的两个数——cancel() 到抛错多久、之后这条 session 还能不能用
        await cancelProbe(remote: remote, connection: connection)

        let measure = await connection.measure
        print("  合计：通道 \(measure.file.channelInits) 条，开句柄 \(measure.file.openCalls) 次，"
              + "fstat \(measure.file.fstatCalls) 次，C 侧净时 \(measure.file.transferElapsedMs) ms，"
              + "碰过 \(measure.executorThreads.count) 条线程（D7 上限 2）")
        await connection.close()
    }

    /// 语料里那份 `.sha256` 也走正式路径下载。
    private static func downloadHash(sidecar: RemotePath, connection: SFTPConnection) async -> String? {
        let target = tempURL("ferry-hash-sidecar")
        defer { try? FileManager.default.removeItem(at: target) }
        guard ((try? await TransferEngine.download(sidecar, to: target, using: connection)) != nil)
        else { return nil }
        guard let text = try? String(contentsOf: target, encoding: .utf8) else { return nil }
        return text.split(separator: " ").first.map(String.init)
    }

    private static func size(of remote: RemotePath, connection: SFTPConnection) async -> Int {
        guard let item = try? await connection.stat(remote) else { return -1 }
        return Int(item.size ?? -1)
    }

    // MARK: - ④ 取消

    private static func cancelProbe(remote: RemotePath, connection: SFTPConnection) async {
        print("  ④ 取消（句柄级标志 + 连接级硬拆）")
        let settle = Double(ProcessInfo.processInfo.environment["SPIKE_SETTLE"] ?? "") ?? 300
        let target = tempURL("ferry-cancel-\(connection.endpoint.port).bin")
        let task = Task {
            try await TransferEngine.download(remote, to: target, using: connection)
        }
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000))
        let started = Date()
        task.cancel()
        var result = "没抛错（跑完了）"
        var latency = msSince(started)
        do { _ = try await task.value }
        catch {
            latency = msSince(started)
            result = token(error)
        }
        let phase = await connection.phase
        // 取消之后再发一次请求：这一发能不能成，决定"取消只废这一个句柄"还是
        // "整条 session 作废"。
        let followUp: String
        if let listing = try? await connection.list(connection.homeDirectory()) {
            followUp = "list 还能用（\(listing.entries.count) 条）"
        } else {
            followUp = "list 也失败了"
        }
        print(String(format: "     settle=%.0f ms  cancel()→抛出 %.1f ms  结果=%@  phase=%@  之后：%@",
                     settle, latency, result as NSString, phase.rawValue as NSString, followUp as NSString))
        let localBytes = ((try? Data(contentsOf: target))?.count ?? -1)
        print("     本地留下 \(localBytes) 字节的半份文件（M3 的 `.part` 才不会把它当成品）")
        try? FileManager.default.removeItem(at: target)
    }

    // MARK: - ⑤ 交错

    private static func interleaveProbe(remote: RemotePath, home: RemotePath,
                                        connection: SFTPConnection) async {
        print("  ⑤ 传输途中交错列目录")
        guard let directory = inHome(home, "spike/list/flat") else { return }
        final class Box: @unchecked Sendable {
            var entries = 0
            var errors: [String] = []
            var rounds = 0
        }
        let box = Box()
        let before = await connection.measure
        let downloadResult = await withTaskGroup(of: String.self) { group -> String in
            group.addTask {
                let target = tempURL("ferry-interleave.bin")
                defer { try? FileManager.default.removeItem(at: target) }
                do {
                    let bytes = try await TransferEngine.download(remote, to: target, using: connection)
                    return "下载 \(bytes) 字节"
                } catch {
                    return "下载失败 \(token(error))"
                }
            }
            group.addTask {
                for _ in 0..<8 {
                    do {
                        let listing = try await connection.list(directory)
                        box.entries += listing.entries.count
                        box.rounds += 1
                    } catch {
                        box.errors.append(token(error))
                    }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                return ""
            }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }
        let after = await connection.measure
        print("     \(downloadResult)；同通道 list 成功 \(box.rounds) 遍共 \(box.entries) 条，"
              + "失败 \(box.errors.isEmpty ? "0 次" : "\(box.errors)")，"
              + "通道增量 \(after.file.channelInits - before.file.channelInits)")
    }

    // MARK: - 本地图层

    private static func localWriteMs() -> Double {
        let started = Date()
        let url = tempURL("ferry-local-probe.bin")
        if let random = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom")),
           let data = try? random.read(upToCount: megabytes * 1_048_576) {
            try? data.write(to: url)
            try? random.close()
        }
        let elapsed = msSince(started)
        try? FileManager.default.removeItem(at: url)
        return elapsed
    }

    private static func localReadMs(url: URL) -> Double {
        let started = Date()
        if let handle = try? FileHandle(forReadingFrom: url) {
            while true {
                let data = (try? handle.read(upToCount: 262_144)) ?? Data()
                if data.isEmpty { break }
            }
            try? handle.close()
        }
        return msSince(started)
    }
}
