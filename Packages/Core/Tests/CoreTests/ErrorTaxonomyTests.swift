import Foundation
import Testing

@testable import FerryCore

private let root = RemotePath(wireBytes: [0x2F], isAbsolute: true)
private let file = RemotePath(wireBytes: [0x2F, 0x61], isAbsolute: true)
private let other = RemotePath(wireBytes: [0x2F, 0x62], isAbsolute: true)

private func ctx(_ op: RemoteOperation, _ path: RemotePath? = file, _ target: RemotePath? = nil,
                 _ caps: RemoteCapabilities? = nil) -> RemoteErrorContext {
    RemoteErrorContext(operation: op, path: path, target: target, capability: caps)
}

@Test("rc 为 0 不是错误；EAGAIN 也不算错误但必须被单独识别")
func successAndWouldBlock() {
    #expect(ErrorTaxonomy.classifySFTP(rc: 0, status: 2, context: ctx(.stat)) == nil)
    #expect(ErrorTaxonomy.classifySession(rc: 0, context: ctx(.handshake)) == nil)

    // 非阻塞轮询下 -37 每秒可能出现成千次。当成可重试的网络错误 = 每次 EAGAIN 重连一回
    #expect(ErrorTaxonomy.isWouldBlock(rc: -37))
    #expect(ErrorTaxonomy.classifySFTP(rc: -37, status: nil, context: ctx(.read)) == nil)
    #expect(!ErrorTaxonomy.isWouldBlock(rc: -9))
}

@Test("notFound 只来自 NO_SUCH_FILE 与 NO_SUCH_PATH")
func notFoundRequiresExistenceStatus() {
    let context = ctx(.stat)
    #expect(ErrorTaxonomy.classifySFTP(rc: -31, status: 2, context: context) == .notFound(path: file))
    #expect(ErrorTaxonomy.classifySFTP(rc: -31, status: 10, context: context) == .notFound(path: file))
}

@Test("rename 撞上已有目标给的是 FX_FAILURE，绝不能翻成 notFound")
func genericFailureIsNeverNotFound() {
    // 实测：OpenSSH 对 rename_ex(目标已存在) 恒回 rc=-31 / status=4（docs/spike/M0a-05 结论 3）
    let rename = ctx(.rename, file, other)
    let error = ErrorTaxonomy.classifySFTP(rc: -31, status: 4, context: rename)

    if case .operationFailed(let failure)? = error {
        #expect(failure.kind == .sftpStatus(.failure))
        #expect(failure.operation == .rename)
        #expect(failure.path == file)
        #expect(failure.target == other)
    } else {
        Issue.record("必须是 operationFailed，实际 \(String(describing: error))")
    }
    // 翻成 notFound 会让同步引擎据此删除本地副本
    #expect(error != .notFound(path: file))
    #expect(error?.isRetryable == false)
    #expect(error?.isFatalToSession == false)
}

@Test("权限类状态码归到 permissionDenied，含 WRITE_PROTECT 与 UNKNOWN_PRINCIPAL")
func permissionStatuses() {
    for status: UInt32 in [3, 12, 16] {
        let error = ErrorTaxonomy.classifySFTP(rc: -31, status: status, context: ctx(.remove))
        #expect(error == .permissionDenied(path: file), "status \(status) 应归 permissionDenied")
        #expect(error?.isRetryable == false)
        #expect(error?.isFatalToSession == false)
    }
}

@Test("rc=-31 却拿不到 status，或 status 自相矛盾，只能判'原因不明'")
func contradictoryOrMissingStatus() {
    // 实测 M0a-02：同 channel 并发请求 rc=-31 且 last_error=0
    #expect(ErrorTaxonomy.classifySFTP(rc: -31, status: nil, context: ctx(.list))?
            .diagnosticCode == "ssh/undetermined(rc=-31)@list")
    #expect(ErrorTaxonomy.classifySFTP(rc: -31, status: 0, context: ctx(.list))?
            .diagnosticCode == "ssh/undetermined(rc=-31)@list")
    #expect(ErrorTaxonomy.classifySFTP(rc: -31, status: nil, context: ctx(.list))?.isRetryable == false)
}

@Test("超界 status 不判成协议违规：symlink_ex 成功时也回 -31 与 71…134")
func outOfRangeStatusIsNotFatal() {
    // 实测 M0b-01 结论 6：16/16 建链成功，返回值却全是 -31、last_error 全是非法值。
    // 判成 protocolViolation 会杀掉整个会话——成功操作引发致命错误。
    let error = ErrorTaxonomy.classifySFTP(rc: -31, status: 71, context: ctx(.symlink))
    if case .operationFailed(let failure)? = error {
        #expect(failure.kind == .sftpStatus(.outOfRange(raw: 71)))
    } else {
        Issue.record("应为 operationFailed，实际 \(String(describing: error))")
    }
    #expect(error?.isFatalToSession == false)
    #expect(error?.diagnosticCode == "sftp/SSH_FX_OUT_OF_RANGE(71)@symlink")

    // BAD_MESSAGE 才是真正的协议层分歧
    #expect(ErrorTaxonomy.classifySFTP(rc: -31, status: 5, context: ctx(.write))?.isFatalToSession == true)
}

@Test("SFTP 的连接类状态码走 network，可重试")
func connectionStatusesRetry() {
    for status: UInt32 in [6, 7] {
        let error = ErrorTaxonomy.classifySFTP(rc: -31, status: status, context: ctx(.read))
        #expect(error == .network(.connectionLost), "status \(status)")
        #expect(error?.isRetryable == true)
        #expect(error?.isFatalToSession == false)
    }
}

@Test("OP_UNSUPPORTED 落到具体能力上，UI 才有东西可降级")
func unsupportedMapsToCapability() {
    let caps = RemoteCapabilities.atomicRenameOverwrite
    #expect(ErrorTaxonomy.classifySFTP(rc: -31, status: 8, context: ctx(.rename, file, other, caps))
            == .unsupported(caps))
    // 没带能力信息时不能凭空造一个
    #expect(ErrorTaxonomy.classifySFTP(rc: -31, status: 8, context: ctx(.rename))?
            .diagnosticCode == "sftp/SSH_FX_OP_UNSUPPORTED@rename")
}

@Test("状态码 0…21 逐个有名，22 起算超界")
func statusTableCoversLegalRange() {
    let names = (0...21).map { SFTPStatus(raw: UInt32($0)).symbolName }
    #expect(names.first == "SSH_FX_OK")
    #expect(names.last == "SSH_FX_LINK_LOOP")
    #expect(names.count == Set(names).count)
    #expect(SFTPStatus(raw: 22) == .outOfRange(raw: 22))
    #expect(SFTPStatus(raw: 131) == .outOfRange(raw: 131))
}

@Test("MaxSessions 用满是 -21，可重试但不是断线")
func channelFailureIsRetryableRefusal() {
    // 实测 M0a-01：两台服务器都在第 11 次 sftp_init 返回 -21（MaxSessions 10）
    let error = ErrorTaxonomy.classifySession(rc: -21, context: ctx(.handshake))
    #expect(error == .network(.connectionRefused))
    #expect(error?.isRetryable == true)
    #expect(error?.isFatalToSession == false)

    #expect(ErrorTaxonomy.classifySession(rc: -9, context: ctx(.read)) == .network(.timeout))
    #expect(ErrorTaxonomy.classifySession(rc: -13, context: ctx(.read)) == .network(.connectionLost))
    #expect(ErrorTaxonomy.classifySession(rc: -46, context: ctx(.handshake))?.isFatalToSession == true)
    #expect(ErrorTaxonomy.classifySession(rc: -51, context: ctx(.handshake))?.isFatalToSession == true)
}

@Test("-16 只有确认带了口令才敢说口令错")
func fileCodeDoesNotImplyPassphrase() {
    // 实测 M0a-05 结论 6：口令错与"私钥格式不支持"共用 -16，且文案会把前者说成文件读不了
    #expect(ErrorTaxonomy.classifyAuth(rc: -16, method: .encryptedKey) == .auth(.passphraseIncorrect))
    #expect(ErrorTaxonomy.classifyAuth(rc: -16, method: .plainKey) == .auth(.keyRejected))
    #expect(ErrorTaxonomy.classifyAuth(rc: -16, method: .agent) == .auth(.keyRejected))

    // -18 同时是 PUBLICKEY_UNRECOGNIZED 的别名，只能靠认证方式区分
    #expect(ErrorTaxonomy.classifyAuth(rc: -18, method: .password) == .auth(.badPassword))
    #expect(ErrorTaxonomy.classifyAuth(rc: -18, method: .plainKey) == .auth(.keyRejected))
    #expect(ErrorTaxonomy.classifyAuth(rc: 0, method: .password) == nil)
    #expect(ErrorTaxonomy.classifyAuth(rc: -13, method: .password) == nil)  // 网络层的事不归这里
    #expect(ErrorTaxonomy.classifyAuth(rc: -18, method: .password)?.isFatalToSession == true)
}

@Test("FTP 的 550 一字多用，永远不据此判定文件不存在")
func ftpFiveFiveZeroNeverMeansAbsent() {
    for op in [RemoteOperation.stat, .openRead, .remove] {
        let error = ErrorTaxonomy.classifyFTP(reply: 550, context: ctx(op))
        #expect(error != .notFound(path: file), "\(op.rawValue) 下 550 不许判成不存在")
        #expect(error?.isRetryable == false)
        #expect(error?.isFatalToSession == false)
    }
    #expect(ErrorTaxonomy.classifyFTP(reply: 550, context: ctx(.stat))?
            .diagnosticCode == "ftp/550@stat")

    #expect(ErrorTaxonomy.classifyFTP(reply: 226, context: ctx(.close)) == nil)
    #expect(ErrorTaxonomy.classifyFTP(reply: 331, context: ctx(.handshake)) == nil)
    #expect(ErrorTaxonomy.classifyFTP(reply: 421, context: ctx(.list)) == .network(.connectionLost))
    #expect(ErrorTaxonomy.classifyFTP(reply: 530, context: ctx(.handshake)) == .auth(.badPassword))
    #expect(ErrorTaxonomy.classifyFTP(reply: 452, context: ctx(.createWrite))?.isRetryable == false)
}

@Test("整棵分类树里只有 network 可重试")
func onlyNetworkRetries() {
    let all: [RemoteError] = [
        .network(.timeout), .network(.dnsFailure), .auth(.badPassword),
        .hostKeyMismatch(fingerprint: "SHA256:x"), .permissionDenied(path: file),
        .notFound(path: file), .keyCollision(existing: file, incoming: other),
        .unsupported(.hashing), .undecodablePath(bytes: [0xFF]),
        .protocolViolation("x"), .localIO(.diskFull),
        .operationFailed(OperationFailure(kind: .sftpStatus(.failure), operation: .stat,
                                         path: file, rc: -31)),
        .operationFailed(OperationFailure(kind: .undetermined, operation: .list, path: root, rc: -31)),
    ]
    for error in all {
        let wantsRetry: Bool
        if case .network = error { wantsRetry = true } else { wantsRetry = false }
        #expect(error.isRetryable == wantsRetry, "\(error.diagnosticCode) 的重试分类跑偏")
    }
    #expect(all.filter(\.isFatalToSession).map(\.diagnosticCode)
            == ["auth/badPassword", "hostKeyMismatch", "protocolViolation"])
    #expect(all.map(\.diagnosticCode).count == Set(all.map(\.diagnosticCode)).count)
}
