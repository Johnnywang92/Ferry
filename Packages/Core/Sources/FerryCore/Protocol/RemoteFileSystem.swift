import Foundation

/// UI 拿到 `RemoteFileSystem` 时连接必然已就绪，所以协议里没有 `connect()`。
public protocol RemoteFileSystem: Sendable {
    func list(_ path: RemotePath) async throws -> [RemoteItem]
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func lstat(_ path: RemotePath) async throws -> RemoteItem
    func openRead(_ path: RemotePath) async throws -> any RemoteReader
    func createWrite(_ path: RemotePath, offset: Int64) async throws -> any RemoteWriter
    func mkdir(_ path: RemotePath, permissions: UInt16?) async throws
    func remove(_ path: RemotePath, recursive: Bool) async throws
    func rename(_ from: RemotePath, to: RemotePath, overwrite: Bool) async throws
    func symlink(target: String, at path: RemotePath) async throws
    func readlink(_ path: RemotePath) async throws -> String
    func chmod(_ path: RemotePath, _ mode: UInt16) async throws
    func statvfs(_ path: RemotePath) async throws -> RemoteVolumeInfo

    /// 大小写与归一化策略属于连接，不属于单个路径。
    var pathPolicy: PathPolicy { get }
}

public protocol RemoteConnection: Sendable {
    /// 登录后协商结果。FTP 的 `FEAT` 常谎报，危险能力默认关闭，需在此显式确认。
    var negotiatedCapabilities: RemoteCapabilities { get }
    func handshake() async throws
    func close() async
    var fileSystem: any RemoteFileSystem { get }
}

public protocol RemoteFileSystemFactory: Sendable {
    /// 后端固有能力的静态声明。
    var declaredCapabilities: RemoteCapabilities { get }
    func makeConnection(_ config: SiteConfig) -> any RemoteConnection
}

/// 站点配置的占位类型；字段在 M1' 连接与认证落地时补全。
public struct SiteConfig: Sendable, Hashable {
    public let host: String
    public let port: Int
    public let username: String

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}
