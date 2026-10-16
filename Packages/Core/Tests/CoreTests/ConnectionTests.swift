import Foundation
import Testing

@testable import FerryCore

/// 指纹的期望值不是我们自算一遍出来的，是从容器里那份 host key 用
/// `ssh-keygen -lf` 读出来的（2026-10-16，ferry-sftp-modern-1）。
/// 用 OpenSSH 当参照系是因为用户手上能对照的只有它：
/// 我们算的串和 `ssh` 弹的串对不上，TOFU 弹窗就等于没有信任链。
@Test("主机密钥指纹与 OpenSSH ssh-keygen 同形（SHA256: + 无填充 base64）")
func fingerprintMatchesOpenSSH() throws {
    let ed25519 = Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIMK3Zj9sOPo9ctD6772F19iXuMJpWqlJXIOn5y46I0E8")!
    #expect(try HostKey(algorithm: "ssh-ed25519", blob: ed25519).fingerprintSHA256
            == "SHA256:WG3BjlCQHyChcmSQT9LFNa/hH7rGRh+RcNvvnZtYTcI")

    // RSA 的 blob 更长，base64 尾部带填充位——去掉填充这一步必须在指纹里生效。
    let rsa = Data(base64Encoded: """
        AAAAB3NzaC1yc2EAAAADAQABAAABgQDPKJSO9xC5ZzLOBzJEMLmk5hG0QAK4GhpUEobjf1mL8ig94b4nu9ha00stfQSA8WE2\
        z3QBhCrxcaBmx/y8kvKi20O8YE4nPH94vFoFLTkuBHJn+EJFUEjK8KYYNteo5Cm3Xl8I09wyI761hf66Mb0qNsu4H4LLHqHK\
        KZNmuAVcm+lGaJvjxreB5s74Yo20ssYQXds18he/3Z4ZqWHILj48N+r+JBsch7wwGrTGESvkYEm2uvTWD6NjYPPxVnCw0xvM\
        YFDEx/o2pyVbUGrbVnzydMHjQpRasNuXiSPJyH1ix5lkhVyH/mQDz43LVK9yISqr98wD4IvE1dHGeiUnw9+4R1l4nM9eThqy\
        GZgHHJn1vaN8Rg5++yUYi4KsW98iuDz1otQShjYppAwNg6QCAbzQhKXzMRryE+7fZUqrRM3+BExDPtBwAKfqlR2zkhArFTDC\
        AyhHdCkQcvRQn42FRcRufKQZGtfh3+wDwLM5C5WVs4gpQZxWtnqVxOqY4tk5yfk=
        """)!
    #expect(try HostKey(algorithm: "ssh-rsa", blob: rsa).fingerprintSHA256
            == "SHA256:c9ML+qdy3dIDWoDMu7ryWKVZWlHzI/JG4AXMuy2nCII")

    // 查表的键是 blob 头部里的名字，不是协商名：协商成 rsa-sha2-512 时 known_hosts 里存的
    // 仍是 `ssh-rsa`（容器实测：`ssh -o HostKeyAlgorithms=rsa-sha2-512` 握手成功后
    // accept-new 写出的行是 `127.0.0.1 ssh-rsa AAAA…`）。拿协商名查表，
    // RSA 主机永远查不到同类型的行，会被误判成"这台只有别的算法"。
    let rsaSha2 = try HostKey(algorithm: "rsa-sha2-512", blob: rsa)
    #expect(rsaSha2.wireType == "ssh-rsa")
    #expect(rsaSha2.algorithm == "rsa-sha2-512")
    #expect(!rsaSha2.isCertificate)

    // 头部长度超出 blob 就是坏 blob：宁可判协议违规，也不能猜一个类型——
    // 猜错类型会直接落到"密钥变了"或"未知主机"两条性质完全不同的分支上。
    #expect(throws: (any Error).self) { try HostKey(algorithm: "ssh-ed25519", blob: Data([0, 0, 0, 9, 0x61])) }
    #expect(throws: (any Error).self) { try HostKey(algorithm: "ssh-ed25519", blob: Data()) }
}

@Test("取消标志：置位单向、时间戳只记第一次")
func cancellationFlagIsOneWay() {
    let flag = CancellationFlag()
    #expect(!flag.isSet)
    #expect(flag.requestedAtNanoseconds == nil)

    flag.cancel()
    let first = flag.requestedAtNanoseconds
    #expect(flag.isSet)

    flag.cancel()
    #expect(flag.requestedAtNanoseconds == first)
}

@Test("含凭据类型的 description 必须脱敏")
func credentialDescriptionIsRedacted() {
    let key = PrivateKeyMaterial(keyData: Data("PRIVATE KEY BODY".utf8), passphrase: "hunter2")
    #expect(!AuthenticationMethod.password("hunter2").description.contains("hunter2"))
    #expect(!AuthenticationMethod.privateKey(key).description.contains("hunter2"))
    #expect(!AuthenticationMethod.privateKey(key).description.contains("PRIVATE KEY BODY"))
    #expect(AuthenticationMethod.privateKey(key).description.contains("16 B"))
    #expect(AuthenticationMethod.sshAgent.description == "sshAgent")
}

@Test("Endpoint.displayString 带用户名但不带任何凭据")
func endpointDisplayString() {
    let endpoint = Endpoint(host: "192.168.1.10", port: 2222, username: "tester")
    #expect(endpoint.displayString == "tester@192.168.1.10:2222")
}

@Test("算法偏好全空 = 库默认，供后端跳过 method_pref")
func algorithmPreferencesEmptiness() {
    #expect(AlgorithmPreferences.libraryDefault.isEmpty)
    #expect(!AlgorithmPreferences(hostKey: ["ssh-rsa"]).isEmpty)
}
