import FerryCore
import Foundation
import Testing

@testable import FerryCore

@Suite("M6: 错误码与排查建议映射表（v2.3 §472）")
struct DiagnosticAdviceTests {

    @Test("网络错误映射包含具体故障原因与恢复指导")
    func networkAdvice() {
        let refused = RemoteError.network(.connectionRefused)
        #expect(refused.actionableAdvice.contains("服务器拒绝连接"))
        #expect(refused.actionableAdvice.contains("22") || refused.actionableAdvice.contains("21"))

        let unreachable = RemoteError.network(.hostUnreachable)
        #expect(unreachable.actionableAdvice.contains("不可达"))

        let timeout = RemoteError.network(.timeout)
        #expect(timeout.actionableAdvice.contains("超时"))

        let lost = RemoteError.network(.connectionLost)
        #expect(lost.actionableAdvice.contains("断点续传"))

        let dns = RemoteError.network(.dnsFailure)
        #expect(dns.actionableAdvice.contains("DNS"))
    }

    @Test("认证错误映射精确区分口令错、公钥拒绝与 agent 缺失")
    func authAdvice() {
        let badPass = RemoteError.auth(.badPassword)
        #expect(badPass.actionableAdvice.contains("密码错误"))

        let keyRej = RemoteError.auth(.keyRejected)
        #expect(keyRej.actionableAdvice.contains("authorized_keys"))

        let passReq = RemoteError.auth(.passphraseRequired)
        #expect(passReq.actionableAdvice.contains("Passphrase") || passReq.actionableAdvice.contains("口令"))

        let passInc = RemoteError.auth(.passphraseIncorrect)
        #expect(passInc.actionableAdvice.contains("口令不正确"))

        let agentUnavail = RemoteError.auth(.agentUnavailable)
        #expect(agentUnavail.actionableAdvice.contains("SSH_AUTH_SOCK"))
    }

    @Test("安全警示与权限错误明确指出指纹与权限位")
    func securityAndPermissionAdvice() {
        let mismatch = RemoteError.hostKeyMismatch(fingerprint: "SHA256:abc123xyz")
        #expect(mismatch.actionableAdvice.contains("中间人攻击") || mismatch.actionableAdvice.contains("安全警示"))
        #expect(mismatch.actionableAdvice.contains("SHA256:abc123xyz"))

        let path = RemotePath(string: "/var/www", isAbsolute: true)!
        let perm = RemoteError.permissionDenied(path: path)
        #expect(perm.actionableAdvice.contains("权限不足"))
    }

    @Test("未解码路径与键碰撞给出字符集与安全暂停指导")
    func pathEncodingAndCollisionAdvice() {
        let undecodable = RemoteError.undecodablePath(bytes: [0xCE, 0xC4])
        #expect(undecodable.actionableAdvice.contains("字符集") || undecodable.actionableAdvice.contains("GBK"))

        let p1 = RemotePath(string: "/a/foo", isAbsolute: true)!
        let p2 = RemotePath(string: "/a/FOO", isAbsolute: true)!
        let collision = RemoteError.keyCollision(existing: p1, incoming: p2)
        #expect(collision.actionableAdvice.contains("碰撞"))
    }
}
