import Foundation

/// 密钥交换实际谈成的六个维度。
///
/// 一律取"线路上谈成的值"，不取配置里写的值：`sshd -T` 打印的是编译期支持的
/// 全集，跟服务器真正发出去的 offer 差得很远（M1-01 §4，OpenSSH 6.7p1 的
/// `-T` 里有全部 CBC 与 `-96`，线路 offer 里一个都没有）。
/// AlgorithmMatrix 和诊断报告只认这个类型。
public struct NegotiatedAlgorithms: Sendable, Hashable {
    public let keyExchange: String
    public let hostKey: String
    public let encryptionClientToServer: String
    public let encryptionServerToClient: String
    public let macClientToServer: String
    public let macServerToClient: String

    public init(
        keyExchange: String,
        hostKey: String,
        encryptionClientToServer: String,
        encryptionServerToClient: String,
        macClientToServer: String,
        macServerToClient: String
    ) {
        self.keyExchange = keyExchange
        self.hostKey = hostKey
        self.encryptionClientToServer = encryptionClientToServer
        self.encryptionServerToClient = encryptionServerToClient
        self.macClientToServer = macClientToServer
        self.macServerToClient = macServerToClient
    }
}

/// 握手完成后的事实。放在一个类型里是因为诊断报告要求"一次连接一组自洽的参数"，
/// 分散取会拿到不同时刻的状态。
public struct NegotiatedSession: Sendable, Hashable {
    /// 服务器 banner 原文，形如 `SSH-2.0-OpenSSH_6.7p1 Debian-5`。
    /// 这是判代（老设备/新设备）的唯一依据，不解析、只原样留档。
    public let serverIdentification: String
    public let hostKey: HostKey
    public let algorithms: NegotiatedAlgorithms

    public init(serverIdentification: String, hostKey: HostKey, algorithms: NegotiatedAlgorithms) {
        self.serverIdentification = serverIdentification
        self.hostKey = hostKey
        self.algorithms = algorithms
    }
}
