import CLibssh2
import Foundation

@main
struct SpikeRunner {
    /// spike #1：同一 session 上连续多次 libssh2_sftp_init()。
    /// 目的是核实 RFC 4254 的事实（单 session 可开多个 SFTP channel），
    /// 并记录超过服务器 MaxSessions 后的失败行为与错误码。
    static func sameSessionMultipleChannels(attempts: Int32) {
        let endpoint = SpikeProbe.Endpoint.fromEnvironment()
        print("libssh2 \(SpikeProbe.version()) -> \(endpoint.host):\(endpoint.port) as \(endpoint.user)")

        let handle: OpaquePointer
        let fd: Int32
        do {
            (fd, handle) = try SpikeProbe.authenticatedSession(endpoint)
        } catch {
            print("FAIL 建立会话失败：\(error)")
            exit(1)
        }
        print("会话已认证，同一 session 上尝试 \(attempts) 次 sftp_init")

        var opened: [OpaquePointer] = []
        var failures: [(index: Int32, code: Int32)] = []

        for index in 0..<attempts {
            let started = Date()
            guard let sftp = libssh2_sftp_init(handle) else {
                var message: UnsafeMutablePointer<CChar>?
                libssh2_session_last_error(handle, &message, nil, 0)
                let code = libssh2_session_last_errno(handle)
                let text = message.map { String(cString: $0) } ?? "<无>"
                failures.append((index, code))
                print(String(format: "  #%02d 失败 %d ms  code=%d  %@", index + 1,
                             Int(Date().timeIntervalSince(started) * 1000), code, text))
                break
            }
            opened.append(sftp)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            print(String(format: "  #%02d 成功 %d ms", index + 1, elapsed))
        }

        print("结果：成功 \(opened.count) 个，失败 \(failures.count) 个")
        for sftp in opened { libssh2_sftp_shutdown(sftp) }
        SpikeProbe.shutdown(session: handle, fd: fd)
        libssh2_exit()
    }

    static func main() {
        libssh2_init(0)
        let arguments = CommandLine.arguments
        let attempts = arguments.count > 1 ? (Int32(arguments[1]) ?? 12) : 12
        sameSessionMultipleChannels(attempts: attempts)
    }
}
