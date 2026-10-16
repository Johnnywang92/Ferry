import Foundation
import Testing

@testable import FerryCore

/// 头部探测的全部依据都来自 M0a-05 结论 6：`-16 FILE` 一个码同时表达三件事，
/// 而这三件事对用户的下一步完全不同。这里只测"读头部读出什么"，
/// 不测解密——本期不在 Swift 层解任何私钥（ADR-0000 §11 H12）。
private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

/// 按真实的 `openssh-key-v1` 形状拼一段头部：magic + cipher 名 + 两个空字段。
/// 只要头部，后面的公钥/私钥体一概不要——探测读到 cipher 就该收手。
private func opensshHead(cipher: String) -> Data {
    var bytes = ascii("openssh-key-v1") + [0]
    func store(_ value: UInt32) {
        bytes += [UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value)]
    }
    func string(_ text: String) {
        store(UInt32(text.utf8.count))
        bytes += Array(text.utf8)
    }
    store(UInt32(cipher.utf8.count))
    bytes += Array(cipher.utf8)
    string("none")        // kdf
    string("")            // ssh-ed25519 公钥串占位
    return Data(bytes)
}

private func pem(label: String, header: [String] = [], body: String = "TWFudWZhY3R1cmVk\n") -> Data {
    var text = "-----BEGIN \(label)-----\n"
    for line in header { text += line + "\n" }
    if !header.isEmpty { text += "\n" }
    text += body
    text += "-----END \(label)-----\n"
    return Data(ascii(text))
}

@Test("openssh-key-v1 的 cipher 字段直接决定明文还是加密")
func opensshHeaderCipherDecides() {
    #expect(PrivateKeyEncryption.probe(opensshHead(cipher: "none")) == .plain)
    #expect(PrivateKeyEncryption.probe(opensshHead(cipher: "aes256-ctr")) == .encrypted)
    #expect(PrivateKeyEncryption.probe(opensshHead(cipher: "3des-cbc")) == .encrypted)

    // 只有 magic、cipher 名的长度前缀都没了：读不出名堂，不许猜成明文。
    #expect(PrivateKeyEncryption.probe(Data(ascii("openssh-key-v1\u{0}"))) == .unrecognized)
    // 长度前缀说谎（比剩余字节还长）同一条纪律。
    var lying = [UInt8](opensshHead(cipher: "none"))
    lying[15] = 0xFF
    #expect(PrivateKeyEncryption.probe(Data(lying)) == .unrecognized)
    // magic 差一个字节就不是这个格式。
    #expect(PrivateKeyEncryption.probe(Data(ascii("openssh-key-v2\u{0}\u{0}\u{0}\u{0}\u{0}none")))
            == .unrecognized)
}

@Test("PEM 的三种加密线索都要认，认不出的一律 unrecognized")
func pemLabelsAndDekInfo() {
    // 老式 RSA/EC/DSA 私钥：没有 DEK-Info / Proc-Type 才是明文。
    #expect(PrivateKeyEncryption.probe(pem(label: "RSA PRIVATE KEY")) == .plain)
    #expect(PrivateKeyEncryption.probe(pem(label: "PRIVATE KEY")) == .plain)
    #expect(PrivateKeyEncryption.probe(pem(label: "EC PRIVATE KEY")) == .plain)
    #expect(PrivateKeyEncryption.probe(pem(label: "RSA PRIVATE KEY",
                                           header: ["Proc-Type: 4,ENCRYPTED",
                                                    "DEK-Info: AES-256-CBC,0123456789ABCDEF"]))
            == .encrypted)
    // PKCS#8 的加密形态把 ENCRYPTED 写在标签里。
    #expect(PrivateKeyEncryption.probe(pem(label: "ENCRYPTED PRIVATE KEY")) == .encrypted)
    // 看不懂的标签不许当明文：判成 plain 之后 -16 会被分类成 keyRejected，
    // 用户去查 authorized_keys，真正的原因却是他没填口令。
    #expect(PrivateKeyEncryption.probe(pem(label: "SSH2 PRIVATE KEY")) == .unrecognized)
    #expect(PrivateKeyEncryption.probe(Data(ascii("PuTTY-User-Key-File-2: ssh-ed25519\n")))
            == .unrecognized)
    #expect(PrivateKeyEncryption.probe(Data()) == .unrecognized)
    #expect(PrivateKeyEncryption.probe(Data([0, 1, 2, 3, 4, 5])) == .unrecognized)
}

@Test("PEM 包着的 OPENSSH 私钥要穿一层看里面的 cipher")
func pemWrappingOpensshIsDecoded() {
    // base64 的头部就是 openssh-key-v1，标签本身只说明"这是 PEM 外壳"。
    func wrapped(_ head: Data) -> Data {
        let text = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + head.base64EncodedString()
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
        return Data(ascii(text))
    }
    #expect(PrivateKeyEncryption.probe(wrapped(opensshHead(cipher: "none"))) == .plain)
    #expect(PrivateKeyEncryption.probe(wrapped(opensshHead(cipher: "aes256-gcm@openssh.com"))) == .encrypted)
    // 外壳在、内容不是 openssh 头部（比如只给了一段短到读不出长度的 base64）：不猜。
    #expect(PrivateKeyEncryption.probe(Data(ascii("""
        -----BEGIN OPENSSH PRIVATE KEY-----
        aGVsbG8=
        -----END OPENSSH PRIVATE KEY-----
        """))) == .unrecognized)
}

@Test("带口令与否 × 是不是加密的，-16 才有三种下一步")
func fileCodeSplitsThreeWays() {
    // 这一条是 M1'-4 的全部理由：三个 AuthMethod 格子对应三种完全不同的用户动作。
    #expect(ErrorTaxonomy.classifyAuth(rc: -16, method: .encryptedKey) == .auth(.passphraseIncorrect))
    #expect(ErrorTaxonomy.classifyAuth(rc: -16, method: .encryptedKeyWithoutPassphrase)
            == .auth(.passphraseRequired))
    #expect(ErrorTaxonomy.classifyAuth(rc: -16, method: .plainKey) == .auth(.keyRejected))
    // 没确认过加密形态的（unrecognized）走 plainKey 那条格，由后端映射，分类器本身不认它
    #expect(ErrorTaxonomy.classifyAuth(rc: -16, method: .agent) == .auth(.keyRejected))
    #expect(ErrorTaxonomy.classifyAuth(rc: -16, method: .keyboardInteractive) == .auth(.keyRejected))

    #expect(ErrorTaxonomy.classifyAuth(rc: -15, method: .password) == .auth(.badPassword))
    #expect(ErrorTaxonomy.classifyAuth(rc: -48, method: .plainKey) == .auth(.keyRejected))
    // methodNotOffered 只能由后端拿服务器自己的清单合成，分类器不许凭码造出来
    for method in [ErrorTaxonomy.AuthMethod.password, .encryptedKey, .plainKey,
                   .encryptedKeyWithoutPassphrase, .agent, .keyboardInteractive] {
        for rc in [Int32(-15), -16, -17, -18, -19, -39, -48] {
            #expect(ErrorTaxonomy.classifyAuth(rc: rc, method: method) != .auth(.methodNotOffered))
        }
    }
}

@Test("auth 的七格都有稳定 token，多出来那格不许顶掉旧格")
func authFailureTokensAreStable() {
    let expected = ["auth/badPassword", "auth/keyRejected", "auth/passphraseRequired",
                    "auth/passphraseIncorrect", "auth/tooManyAuthAttempts", "auth/methodNotOffered",
                    "auth/agentUnavailable"]
    #expect(Set(AuthFailure.allCases.map { "auth/\($0.rawValue)"}) == Set(expected))
    // rawValue 是导出过的聚合键，重写文案可以，改值不行
    #expect(AuthFailure.methodNotOffered.rawValue == "methodNotOffered")
    #expect(AuthFailure.agentUnavailable.rawValue == "agentUnavailable")
    #expect(RemoteError.auth(.methodNotOffered).isFatalToSession == false)
    #expect(RemoteError.auth(.methodNotOffered).isRetryable == false)
}

@Test("认证方式与结果的载荷")
func authenticatedSessionCarriesFacts() {
    let session = AuthenticatedSession(method: .agent, serverOfferedMethods: ["publickey", "password"],
                                       agentIdentity: "ferry-agent-test")
    #expect(session.method.rawValue == "agent")
    #expect(AuthenticatedMethod.keyboardInteractive.rawValue == "keyboard-interactive")
    #expect(session.serverOfferedMethods == ["publickey", "password"])
    #expect(session.agentIdentity == "ferry-agent-test")
    #expect(AuthenticatedSession(method: .none, serverOfferedMethods: []).agentIdentity == nil)
    // Hashable：诊断报告要能把同一个结果当键用
    #expect(Set([session, session]).count == 1)
}
