import FerryCore
import Foundation

/// SFTP 后端入口。主机密钥的信任判定在这里注入而不是在每条连接里选：
/// 一台设备上 TOFU 策略是全局的，不该让调用点各写各的。
public struct SFTPBackend: RemoteBackend {
    /// 后端固有上限，取自 v2.3 §Capability 的 SFTP 列。
    /// 不含 `serverSideCopy`（SFTP 没有服务端复制）、`hashing`（v3 没有哈希扩展）
    /// 和 `charsetNegotiation`（SFTP 名义上固定 UTF-8，没什么可谈）。
    /// 本次会话实际能用哪些要等握手与 `sftp_init` 扩展协商完，属 M1'-5。
    public let declaredCapabilities: RemoteCapabilities

    private let hostKeyTrust: any HostKeyTrust

    public init(hostKeyTrust: any HostKeyTrust) {
        self.hostKeyTrust = hostKeyTrust
        self.declaredCapabilities = [
            .resumableDownload, .resumableUpload, .permissions, .ownership,
            .symbolicLinks, .lstat, .directoryStat, .atomicRenameOverwrite, .reliableMTime
        ]
    }

    public func makeConnection(_ request: ConnectionRequest) -> any RemoteConnection {
        SFTPConnection(request: request, hostKeyTrust: hostKeyTrust)
    }
}
