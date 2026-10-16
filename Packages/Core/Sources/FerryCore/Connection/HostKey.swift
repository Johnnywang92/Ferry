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
    /// 本次密钥交换**协商到的签名算法名**，如 `rsa-sha2-512`、`ssh-ed25519`。
    /// 这是协商维度的事实，进 `NegotiatedAlgorithms`，但不能拿它去查 known_hosts，见 `wireType`。
    public let algorithm: String
    /// blob 头部自带的算法名，即 known_hosts 里 keytype 字段用的那个名字。
    ///
    /// 两者在 RSA 上必然分家：协商可以是 `rsa-sha2-512`，而 known_hosts 存的是 `ssh-rsa`
    /// （实测：容器里 `ssh -o HostKeyAlgorithms=rsa-sha2-512` 握手成功后，
    /// accept-new 写进文件的行是 `127.0.0.1 ssh-rsa AAAA…`）。
    /// 所以信任判定的查表键只能是 `wireType`——用 `algorithm` 查会在 RSA 主机上
    /// 永远查不到同类型的行，把正常重连误判成"这台主机只有别的算法"。
    public let wireType: String
    public let blob: Data
    public let fingerprintSHA256: String

    /// `blob` 必须是完整的 SSH public key blob（4 字节长度前缀 + 算法名 + 各算法参数），
    /// 也就是 `ssh-keygen -lf` 读的那个结构。头部不成形时抛协议违规而不是猜一个类型：
    /// 猜错类型会直接落到"密钥变了/未知主机"这两条完全不同性质的分支上。
    public init(algorithm: String, blob: Data) throws {
        guard blob.count > 4 else {
            throw RemoteError.protocolViolation("主机密钥 blob 太短，读不出算法名：\(blob.count) 字节")
        }
        let nameLength = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard nameLength > 0, nameLength <= blob.count - 4,
              let name = String(data: blob.subdata(in: 4..<(4 + nameLength)), encoding: .ascii) else {
            throw RemoteError.protocolViolation("主机密钥 blob 头部不成形：声明长度 \(nameLength)，总长 \(blob.count)")
        }
        self.algorithm = algorithm
        self.wireType = name
        self.blob = blob
        self.fingerprintSHA256 = "SHA256:" +
            Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// known_hosts 里的密钥类型以 `-cert-v…@openssh.com` 结尾的就是主机密钥证书。
    /// 本期不做证书校验（ADR-0000 §9 N3），遇到只说明原因，不当普通密钥比。
    public var isCertificate: Bool { wireType.contains("-cert-") }

    /// 落进 known_hosts 格式那一行的后两个字段。
    public var knownHostsKeyFields: String { "\(wireType) \(blob.base64EncodedString())" }

    /// 从表里读到的 blob 直接算指纹，给"密钥变了"的弹窗用——这时手上只有文件里那串字节，
    /// 没有协商上下文，构造不出完整的 `HostKey`。
    public static func fingerprint(of blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// 握手与认证之间的信任判定。由 `HostKeyStore`（M1'-3）实现。
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
