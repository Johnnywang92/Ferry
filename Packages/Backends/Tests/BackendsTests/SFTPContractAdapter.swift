import CLibssh2
import FerryCore
import Foundation

@testable import FerryBackendsSFTP

/// 把 `SFTPConnection` 适配成 `RemoteFileSystem`，只暴露它**已经实现**的那部分。
///
/// 为什么要这一层而不是让 `SFTPConnection` 直接 conform `RemoteFileSystem`
/// （`Protocol/RemoteFileSystem.swift` 顶上那段注释里明确说"现在还不声称 conform"）：
/// 它有六条操作还没实现——`mkdir` / `remove` / `rename` / `symlink` / `chmod` / `statvfs`。
/// 现在就声称 conform 等于交出一个处处抛"未实现"的壳，而**契约测试恰好是这类壳的照妖镜**：
/// 套件里那几格一跑就会红，红的原因是"壳在抛错"而不是"后端做错了"，
/// 于是真正该看的信号被噪声淹掉。
///
/// 这一层把边界画在类型里：契约拿到的 `any RemoteFileSystem` 就是能用的全部，
/// 不在列表里的操作在这条路径上压根不存在。等那六条补齐，把这个适配器删掉、
/// `SFTPConnection` 直接 conform 即可——契约用例一行都不用改，因为它们只认协议。
///
/// `list` / `stat` / `lstat` / `resolve` / `readlink` 直接转发，
/// `statvfs` 走 SFTP v3 没有对应包这一事实（下面有说明）。
public struct SFTPContractAdapter: RemoteFileSystem {
    private let connection: SFTPConnection

    // MARK: - 转发到 SFTPConnection

    public func list(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        try await connection.list(path)
    }

    public func stat(_ path: RemotePath) async throws -> RemoteItem {
        try await connection.stat(path)
    }

    public func lstat(_ path: RemotePath) async throws -> RemoteItem {
        try await connection.lstat(path)
    }

    public func resolve(_ item: RemoteItem, in listing: inout RemoteDirectoryListing)
        async throws -> RemoteDirectoryListing.LinkResolution?
    {
        try await connection.resolve(item, in: &listing)
    }

    public func readlink(_ path: RemotePath) async throws -> RemotePath {
        try await connection.readlink(path)
    }

    public func openRead(_ path: RemotePath) async throws -> any RemoteReader {
        try await connection.openRead(path)
    }

    public func openRead(_ path: RemotePath, offset: Int64) async throws -> any RemoteReader {
        try await connection.openRead(path, offset: offset)
    }

    public func createWrite(_ path: RemotePath, offset: Int64) async throws -> any RemoteWriter {
        try await connection.createWrite(path, offset: offset)
    }

    // MARK: - 尚未实现的那六条

    // 下面的每个都不是 `fatalError`，而是**诚实地报错**：错误里必须一眼看出
    // "这条是本适配器没转发"，而不是"服务器拒绝"——后者会让排查的人跑去查 sshd。
    // `fatalError` 更糟：契约套件里它表现为一次看不懂的进程崩溃。

    private func notForwarded(_ operation: String) -> RemoteError {
        RemoteError.protocolViolation("SFTPContractAdapter 未转发 \(operation)：SFTP 后端尚未实现")
    }

    public func mkdir(_ path: RemotePath, permissions: UInt16?) async throws {
        throw notForwarded("mkdir")
    }

    public func remove(_ path: RemotePath, recursive: Bool) async throws {
        throw notForwarded("remove")
    }

    public func rename(_ from: RemotePath, to: RemotePath, overwrite: Bool) async throws {
        throw notForwarded("rename")
    }

    public func symlink(target: RemotePath, at path: RemotePath) async throws {
        throw notForwarded("symlink")
    }

    public func chmod(_ path: RemotePath, _ mode: UInt16) async throws {
        throw notForwarded("chmod")
    }

    /// SFTP v3 没有 `SSH_FXP_EXTENDED` 之外的卷信息请求（`statvfs` 那条扩展在
    /// OpenSSH 上要 OpenSSH 特有扩展号，libssh2 不封装），所以这一格拿不到值。
    /// 返回 nil 而不是报错：契约与调用方都把它当"可空信息"，
    /// 而报错会让 UI 弹一个"服务器不支持"的错条——那不是服务器的错，是我们还没接。
    public func statvfs(_ path: RemotePath) async throws -> RemoteVolumeInfo {
        RemoteVolumeInfo(totalBytes: nil, availableBytes: nil)
    }

    // MARK: - 属性

    /// 协议要求这两个是**同步**属性，而 `SFTPConnection` 是 actor、取它们要 await。
    /// 所以适配器构造时各读一次存下来。
    ///
    /// 存副本而不是每次现取，是因为它们在连接生命周期内是常量（来自
    /// `ConnectionRequest`），而每次现取会让一个同步 getter 变成 async——
    /// 那正是协议当初把它们定义成同步的原因（R5：显示字符集属于连接，不属于路径）。
    private let cachedPathPolicy: PathPolicy
    private let cachedCharsetConverter: CharsetConverter

    public var pathPolicy: PathPolicy { cachedPathPolicy }

    public var charsetConverter: CharsetConverter { cachedCharsetConverter }

    public init(_ connection: SFTPConnection) {
        self.connection = connection
        self.cachedPathPolicy = connection.pathPolicy
        self.cachedCharsetConverter = connection.charsetConverter
    }
}
