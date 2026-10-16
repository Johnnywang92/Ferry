import Darwin
import FerryCore
import Foundation

/// TCP 建连与 socket 本身。只做两件事：带超时地把连接建起来，以及交出 fd。
///
/// 建连必须是非阻塞 connect + poll。阻塞 `connect()` 卡在 SYN 里时
/// 既收不到超时也收不到取消——ADR-0001 D5 说"建阶段也走同一台机器"，
/// 第一段就包括三次握手，否则用户对着一个不可达 IP 只能干等内核默认的 75 秒。
struct TCPStream {
    let fd: Int32

    /// poll 切片上限（ADR-0001 D3：实测 200 ms 切片得到 198.5 ms 取消延迟，所以定 50 ms）。
    static let pollSliceMs: Int32 = 50

    static func connect(endpoint: Endpoint, timeout: Duration, cancel: CancellationFlag,
                        stats: LoopStats = LoopStats()) throws -> TCPStream {
        let deadline = uptimeMilliseconds() + milliseconds(of: timeout)

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // v4/v6 都试：容器里 127.0.0.1 与 ::1 混着用很常见
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var addresses: UnsafeMutablePointer<addrinfo>?
        let dnsRC = endpoint.host.withCString { getaddrinfo($0, String(endpoint.port), &hints, &addresses) }
        guard dnsRC == 0, let first = addresses else {
            throw RemoteError.network(.dnsFailure)
        }
        defer { freeaddrinfo(first) }

        var lastError: Int32 = 0
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor?.pointee {
            cursor = entry.ai_next

            if cancel.isSet { throw CancellationError() }
            if uptimeMilliseconds() >= deadline { throw RemoteError.network(.timeout) }
            guard let address = entry.ai_addr else { continue }

            let fd = socket(entry.ai_family, entry.ai_socktype, entry.ai_protocol)
            guard fd >= 0 else { lastError = errno; continue }

            // 对端在握手中途断开时，后续的 write() 会发 SIGPIPE 直接打死进程。
            var ignoreSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &ignoreSigPipe, socklen_t(MemoryLayout<Int32>.size))

            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                lastError = errno
                close(fd)
                continue
            }

            let rc = address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, entry.ai_addrlen)
            }
            if rc != 0, errno != EINPROGRESS, errno != EWOULDBLOCK, errno != EISCONN {
                lastError = errno
                close(fd)
                continue
            }

            do {
                try awaitReady(fd: fd, deadline: deadline, cancel: cancel, stats: stats)
                return TCPStream(fd: fd)
            } catch let error as RemoteError {
                close(fd)
                // 超时/不可达是这一整个地址预算的失败，不再换下一个候选地址硬试。
                throw error
            } catch {
                close(fd)
                throw error
            }
        }
        throw networkError(for: lastError)
    }

    /// 等这条非阻塞连接可用：每片 `pollSliceMs` 就回到顶部查一次取消。
    private static func awaitReady(fd: Int32, deadline: Int64, cancel: CancellationFlag,
                                   stats: LoopStats) throws {
        while true {
            if cancel.isSet { throw CancellationError() }
            let remaining = deadline - uptimeMilliseconds()
            if remaining <= 0 { throw RemoteError.network(.timeout) }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLOUT), revents: 0)
            let slice = Int32(min(Int64(pollSliceMs), remaining))
            stats.polls += 1
            let rc = withUnsafeMutablePointer(to: &descriptor) { poll($0, 1, slice) }

            if rc == 0 { stats.pollTimeouts += 1; continue }
            if rc < 0 {
                if errno == EINTR { continue }
                throw RemoteError.network(.connectionLost)
            }

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            let queryRC = withUnsafeMutablePointer(to: &socketError) {
                getsockopt(fd, SOL_SOCKET, SO_ERROR, $0, &length)
            }
            guard queryRC == 0 else { throw RemoteError.network(.connectionLost) }
            guard socketError == 0 else { throw networkError(for: socketError) }
            return
        }
    }
}

func networkError(for code: Int32) -> RemoteError {
    switch code {
    case ECONNREFUSED: .network(.connectionRefused)
    case ETIMEDOUT: .network(.timeout)
    case EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN: .network(.hostUnreachable)
    default: .network(.connectionLost)
    }
}
