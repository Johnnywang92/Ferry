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
    }

    static func main() {
        libssh2_init(0)
        defer { libssh2_exit() }
        let arguments = CommandLine.arguments
        let mode = arguments.count > 1 ? arguments[1] : "throughput"
        switch mode {
        case "channels":
            let attempts = arguments.count > 2 ? (Int32(arguments[2]) ?? 12) : 12
            sameSessionMultipleChannels(attempts: attempts)
        case "throughput":
            ThroughputSpike.run()
        case "latency":
            ThroughputSpike.latencyMain()
        case "cancel":
            CancelSpike.run()
        case "small":
            SmallFileSpike.run()
        case "keys":
            KeySpike.run()
        case "rename":
            RenameSpike.run()
        case "paths":
            PathOracleSpike.run()
        case "charset":
            CharsetProbe.run()
        case "handshake", "auth":
            // 正式实现是 actor，探针要等它跑完，用信号量把 main() 钉住。
            // 但 main() 隐含 @MainActor：Task {} 会继承主执行器，而主线程正卡在
            // done.wait() 上，任务永远轮不到执行——所以必须显式离开主线程。
            setbuf(stdout, nil)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    if mode == "auth" { await AuthSpike.run() } else { await HandshakeProbe.run() }
                    done.signal()
                }
            }
            done.wait()
        default:
            print("用法：spike [channels <次数> | throughput | latency | cancel | small | keys | rename | paths | charset | handshake | auth]")
            print("  throughput 可用环境变量 SPIKE_FILE / SPIKE_CHUNK / SPIKE_LEVELS 调整负载")
            print("  latency 可用环境变量 SPIKE_REQUESTS / SPIKE_REQ_SIZE 调整请求数与大小")
            print("  paths 默认打到 2201（atmoz），用 SPIKE_PORT 换成其它服务器对照")
            print("  handshake 可用 SPIKE_PORTS / SPIKE_PREFS=legacy / SPIKE_EXPERIMENT=stall 调整")
            print("  auth 可用 SPIKE_PORTS / SPIKE_PORT / SPIKE_KEY_DIR / SPIKE_EXPERIMENT=tries|cancel|stuckagent 调整")
            exit(2)
        }
    }
}
