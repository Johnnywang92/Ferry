import Foundation

/// 文件系统操作。实现它的是已完成握手的连接（`RemoteConnection`，
/// 见 `Connection/RemoteBackend.swift`），所以协议里没有 `connect()`：
/// UI 拿到 `RemoteFileSystem` 时连接必然已就绪。
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
