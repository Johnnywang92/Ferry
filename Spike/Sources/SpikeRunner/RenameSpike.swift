import CLibssh2
import Foundation

/// spike #7 的运行时那一半：头文件里有 `libssh2_sftp_posix_rename_ex` 不等于能用。
/// posix-rename@openssh.com 是扩展，服务器不支持时行为如何、
/// 以及"重名覆盖"到底走哪条语义，直接决定上传重名冲突的实现。
enum RenameSpike {

    struct Case {
        let label: String
        let flags: Int
        let posix: Bool
        let destExists: Bool
    }

    static func run() {
        libssh2_init(0)
        defer { libssh2_exit() }
        let endpoint = SpikeProbe.Endpoint.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        let dir = env["SPIKE_RENAME_DIR"] ?? "/home/tester/spike/upload"
        let native = Int(LIBSSH2_SFTP_RENAME_NATIVE)
        let overwrite = Int(LIBSSH2_SFTP_RENAME_OVERWRITE)
        let atomic = Int(LIBSSH2_SFTP_RENAME_ATOMIC)

        print("libssh2 \(SpikeProbe.version()) -> \(endpoint.host):\(endpoint.port)，目录 \(dir)")
        print(String(format: "  %-46@ %6@  %@", "用例", "rc", "结果"))

        let cases: [Case] = [
            Case(label: "posix_rename，目标不存在", flags: 0, posix: true, destExists: false),
            Case(label: "posix_rename，目标已存在", flags: 0, posix: true, destExists: true),
            Case(label: "rename_ex NATIVE，目标不存在", flags: native, posix: false, destExists: false),
            Case(label: "rename_ex NATIVE，目标已存在", flags: Int(native), posix: false, destExists: true),
            Case(label: "rename_ex OVERWRITE|ATOMIC|NATIVE（宏默认），目标已存在",
                 flags: overwrite | atomic | native, posix: false, destExists: true),
            Case(label: "rename_ex OVERWRITE|ATOMIC，目标已存在",
                 flags: overwrite | atomic, posix: false, destExists: true)
        ]

        for testCase in cases {
            do {
                try attempt(testCase, endpoint: endpoint, dir: dir)
            } catch {
                print("  \(testCase.label)：异常 \(error)")
            }
        }
    }

    static func attempt(_ testCase: Case, endpoint: SpikeProbe.Endpoint, dir: String) throws {
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        defer { SpikeProbe.shutdown(session: session, fd: fd) }
        guard let sftp = libssh2_sftp_init(session) else {
            throw ThroughputSpike.Failure(step: "sftp_init", detail: ThroughputSpike.lastSessionError(session))
        }
        defer { libssh2_sftp_shutdown(sftp) }

        let source = dir + "/rn-src.txt"
        let dest = dir + "/rn-dst.txt"
        let filler = dir + "/rn-filler.txt"
        let payload = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        defer { payload.deallocate() }
        strcpy(payload, "ferry-s")

        // 每轮都从干净状态开始：先删掉上一轮可能留下的 src/dst
        for path in [source, dest] {
            _ = path.withCString { libssh2_sftp_unlink_ex(sftp, $0, UInt32(strlen($0))) }
        }
        _ = try SmallFileSpike.writeOne(sftp, path: source, buffer: payload, size: 8)
        if testCase.destExists {
            _ = try SmallFileSpike.writeOne(sftp, path: dest, buffer: payload, size: 8)
        }

        let rc: Int32 = source.withCString { src in
            dest.withCString { dst in
                testCase.posix
                    ? libssh2_sftp_posix_rename_ex(sftp, src, strlen(src), dst, strlen(dst))
                    : libssh2_sftp_rename_ex(sftp, src, UInt32(strlen(src)), dst, UInt32(strlen(dst)),
                                             testCase.flags)
            }
        }
        // 必须在做后续 stat 之前取，last_error 会被下一个请求覆盖
        let lastError = rc != 0 ? libssh2_sftp_last_error(sftp) : 0
        let sourceGone = SmallFileSpike.statOne(sftp, path: source) == nil
        let destPresent = SmallFileSpike.statOne(sftp, path: dest) != nil

        var note = "源\(sourceGone ? "已消失" : "仍在")，目标\(destPresent ? "存在" : "不存在")"
        if rc != 0 {
            note += "；rc=\(rc) sftp_last_error=\(lastError) \(ThroughputSpike.lastSessionError(session))"
        }
        print(String(format: "  %-46@ %6d  %@", testCase.label as NSString, rc, note as NSString))
    }
}
