import FerryCore
import Foundation

/// FTP/FTPS 后端入口（v2.3 §67, §174, §271）。
public struct FTPBackend: RemoteBackend {
    public let declaredCapabilities: RemoteCapabilities
    public let isFTPS: Bool

    public init(isFTPS: Bool = false) {
        self.isFTPS = isFTPS
        self.declaredCapabilities = [
            .resumableDownload,
            .resumableUpload,
            .reliableMTime,
            .charsetNegotiation
        ]
    }

    public func makeConnection(_ request: ConnectionRequest) -> any RemoteConnection {
        FTPConnection(request: request, isFTPS: isFTPS)
    }
}
