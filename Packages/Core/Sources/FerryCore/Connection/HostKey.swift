import CryptoKit
import Foundation

/// 服务器在密钥交换里给出的主机密钥。
///
/// `blob` 是 SSH wire 格式的公钥主体（算法名之外的裸字节，即
/// `ssh-keygen -lf` 读的那个结构），`fingerprintSHA256` 由它算出，
/// 与 OpenSSH 同形：`SHA256:` + base64(SHA-256(blob)) 去掉填充位。
/// 同形不是审美问题——用户会拿 `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub`
/// 或 `ssh -o VisualHostKey` 的输出跟我们的弹窗对照，对不上就等于没有信任链。
public struct HostKey: Sendable, Hashable {
    /// 协商出的主机密钥算法名，如 `ssh-ed25519`、`ssh-rsa`。
    public let algorithm: String
    public let blob: Data
    public let fingerprintSHA256: String

    public init(algorithm: String, blob: Data) {
        self.algorithm = algorithm
        self.blob = blob
        self.fingerprintSHA256 = "SHA256:" +
            Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// 握手与认证之间的信任判定。M1'-3 的 HostKeyStore 实现它；
/// M1'-2 只留接缝，因为指纹的存储与比对不属于连接层。
///
/// 判定发生在 kex **之后**：libssh2 没有"验证回调"，主机密钥只能在
/// `libssh2_session_handshake` 返回后取。这不是缺陷——认证还没开始，
/// 拒绝时直接把 socket 掐掉，凭据一个字节都不会发出去（M1-02 §3 实测）。
public protocol HostKeyTrust: Sendable {
    /// 通过就返回；不通过抛 `RemoteError.hostKeyMismatch(fingerprint:)`，
    /// 或调用方自己的取消/交互错误。
    func evaluate(endpoint: Endpoint, hostKey: HostKey) async throws
}
