import Foundation

/// 文件系统操作。实现它的是已完成握手的连接（`RemoteConnection`，
/// 见 `Connection/RemoteBackend.swift`），所以协议里没有 `connect()`：
/// UI 拿到 `RemoteFileSystem` 时连接必然已就绪。
///
/// 本里程碑只实现前三条（M1'-5：目录列表与 stat/lstat）。上下传那两条已经在
/// `RemoteTransfer` 里交付（M1'-6），但 mkdir/remove/rename/symlink/chmod/statvfs 还没有，
/// 所以 **`SFTPConnection` 现在还不声称 conform 本协议**——
/// 与其交出一个处处抛"未实现"的壳，不如让类型检查等实现齐了再上（M1'-2 同一条理由）。
public protocol RemoteFileSystem: RemoteTransfer {
    /// 一次列完，属性来自 readdir 同一个包（ADR-0001 D8：禁止逐条 stat）。
    /// 返回的清单自带软链解析缓存，见 `RemoteDirectoryListing`。
    func list(_ path: RemotePath) async throws -> RemoteDirectoryListing
    func stat(_ path: RemotePath) async throws -> RemoteItem
    func lstat(_ path: RemotePath) async throws -> RemoteItem
    /// 把一条软链解析到底，结果写进清单的缓存里；已解析过的条目直接命中缓存，
    /// 不再向服务器发任何请求。
    func resolve(_ item: RemoteItem, in listing: inout RemoteDirectoryListing) async throws
        -> RemoteDirectoryListing.LinkResolution?
    func mkdir(_ path: RemotePath, permissions: UInt16?) async throws
    func remove(_ path: RemotePath, recursive: Bool) async throws
    func rename(_ from: RemotePath, to: RemotePath, overwrite: Bool) async throws
    func symlink(target: RemotePath, at path: RemotePath) async throws
    /// 与 `RemoteItem.linkTarget` 同形：返回原始字节，不猜字符集。
    func readlink(_ path: RemotePath) async throws -> RemotePath
    func chmod(_ path: RemotePath, _ mode: UInt16) async throws
    func statvfs(_ path: RemotePath) async throws -> RemoteVolumeInfo

    /// 大小写与归一化策略属于连接，不属于单个路径。
    var pathPolicy: PathPolicy { get }
    /// 文件名的显示字符集（R5）。寻址永远用 `wireBytes`，这个只管显示与输入编码。
    var charsetConverter: CharsetConverter { get }
}
