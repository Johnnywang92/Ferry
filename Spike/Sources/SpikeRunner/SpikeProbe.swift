import CLibssh2
import Foundation

/// spike 期间直接以阻塞模式握手，故意绕开 Core 抽象，
/// 这样测出来的行为差异只能来自 libssh2 与服务器本身。
enum SpikeProbe {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let code: Int32
        var description: String { "libssh2 \(step) 失败，返回码 \(code)" }
    }

    struct Endpoint {
        let host: String
        let port: UInt16
        let user: String
        let password: String

        static func fromEnvironment(defaultPort: UInt16 = 2202) -> Endpoint {
            let env = ProcessInfo.processInfo.environment
            return Endpoint(
                host: env["SPIKE_HOST"] ?? "127.0.0.1",
                port: UInt16(env["SPIKE_PORT"] ?? "") ?? defaultPort,
                user: env["SPIKE_USER"] ?? "tester",
                password: env["SPIKE_PASS"] ?? "testpass"
            )
        }
    }

    static func openSocket(_ endpoint: Endpoint) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(step: "socket", code: errno) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            throw Failure(step: "connect \(endpoint.host):\(endpoint.port)", code: Int32(errno))
        }

        // spike #4/#5 用：libssh2 的 session_set_blocking(0) 是否自己把套接字
        // 置成非阻塞，直接决定 poll 边界能不能按时拿到取消信号。
        if ProcessInfo.processInfo.environment["SPIKE_NONBLOCK_SOCKET"] == "1" {
            let flags = fcntl(fd, F_GETFL, 0)
            fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        // spike #2/#3 用：判断单 Session 多 Channel 的天花板究竟是
        // libssh2 的请求串行化，还是这一条 TCP 自身的接收窗口。
        if let size = ProcessInfo.processInfo.environment["SPIKE_RCVBUF"], let bytes = Int(size), bytes > 0 {
            var value = Int32(bytes)
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &value, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &value, socklen_t(MemoryLayout<Int32>.size))
        }
        return fd
    }

    /// 只做到握手完成、**不认证**，用于测私钥解析路径（认证才是网络行为）。
    static func unauthenticatedSession(_ endpoint: Endpoint) throws -> (fd: Int32, session: OpaquePointer) {
        let fd = try openSocket(endpoint)
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            close(fd)
            throw Failure(step: "session_init", code: -1)
        }
        let rc = libssh2_session_handshake(session, fd)
        guard rc == 0 else {
            libssh2_session_free(session)
            close(fd)
            throw Failure(step: "handshake", code: rc)
        }
        return (fd, session)
    }

    /// 建立已完成用户认证的 session；调用方负责释放返回的 session 与 fd。
    static func authenticatedSession(_ endpoint: Endpoint) throws -> (fd: Int32, session: OpaquePointer) {
        let fd = try openSocket(endpoint)

        // libssh2_session_init 是宏，Swift 导入不到，展开成 _ex 调用
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            close(fd)
            throw Failure(step: "session_init", code: -1)
        }

        let handshakeRC = libssh2_session_handshake(session, fd)
        guard handshakeRC == 0 else {
            libssh2_session_free(session)
            close(fd)
            throw Failure(step: "handshake", code: handshakeRC)
        }

        // libssh2_userauth_password 同样是宏（内部做 strlen），需展开为 _ex 并自己传长度
        let authRC = endpoint.user.withCString { user in
            endpoint.password.withCString { password in
                libssh2_userauth_password_ex(
                    session,
                    user,
                    UInt32(strlen(user)),
                    password,
                    UInt32(strlen(password)),
                    nil
                )
            }
        }
        guard authRC == 0 else {
            // libssh2_session_disconnect 是函数式宏，Swift 无法导入，直接调 _ex 版本
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "spike auth failed", "")
            libssh2_session_free(session)
            close(fd)
            throw Failure(step: "userauth_password", code: authRC)
        }

        return (fd, session)
    }

    static func version() -> String {
        guard let pointer = libssh2_version(0) else { return "unknown" }
        return String(cString: pointer)
    }

    static func shutdown(session: OpaquePointer, fd: Int32) {
        libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "spike done", "")
        libssh2_session_free(session)
        close(fd)
    }
}
