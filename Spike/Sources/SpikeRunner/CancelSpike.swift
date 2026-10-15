import CLibssh2
import Foundation

/// spike #4/#5：取消与打断的代价。
///
/// #4 —— 非阻塞 poll 循环里，从"外部置取消标志"到"循环真正退出"要多久。
///        方案 v2.3 的出口标准是 200 ms 内取消，这一条取决于 poll 的超时切片。
/// #5 —— 已经卡在阻塞 libssh2 调用里时，只能用 `shutdown(socket)` 打断，
///        测打断生效要多久、调用返回什么、之后 session 能不能安全释放。
///
/// 需要服务端"慢"才能测出等待中的行为，所以这组用 tc netem 把容器出口
/// 延迟拉到 1 s（见 docs/spike/M0a-03）。
enum CancelSpike {

    static func run() {
        let endpoint = SpikeProbe.Endpoint.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        let path = env["SPIKE_FILE"] ?? "/home/tester/spike/big.bin"
        let chunk = Int(env["SPIKE_CHUNK"] ?? "") ?? 262_144
        let settle = Double(env["SPIKE_SETTLE"] ?? "") ?? 1.5
        let timeouts = (env["SPIKE_POLL_TIMEOUTS"] ?? "50,200,1000,5000")
            .split(separator: ",").compactMap { Int($0) }

        print("libssh2 \(SpikeProbe.version()) -> \(endpoint.host):\(endpoint.port)")
        print("取消实验：稳定 \(settle) s 后置取消标志，poll 超时切片 \(timeouts) ms")

        let modes = (env["SPIKE_CANCEL_MODES"] ?? "parked,setup")
            .split(separator: ",").map(String.init)
        // abort=1：取消后不做体面关闭，直接 shutdown + session_free（推荐的取消收尾）
        let abort = env["SPIKE_CANCEL_ABORT"] == "1"
        print("收尾方式：\(abort ? "掐 socket（abort）" : "libssh2 体面关闭（orderly）")")

        for mode in modes {
            print(mode == "parked"
                  ? "取消点在 poll 边界（建阶段已完成，循环停在等响应）："
                  : "取消点在建阶段（sftp_init / open 仍是阻塞调用）：")
            for timeout in timeouts {
                do {
                    try measureCancellation(endpoint: endpoint, path: path, chunk: chunk,
                                            settle: settle, pollTimeoutMs: timeout,
                                            waitMode: mode, abort: abort)
                } catch {
                    print("  poll=\(timeout) ms 失败：\(error)")
                }
            }
        }

        if !abort {
            do {
                try measureBlockingInterrupt(endpoint: endpoint, path: path, chunk: chunk, settle: settle)
            } catch {
                print("  阻塞打断失败：\(error)")
            }
            let idleChannels = Int(env["SPIKE_COLLATERAL_CHANNELS"] ?? "") ?? 3
            do {
                try measureCollateral(endpoint: endpoint, path: path, chunk: chunk,
                                      settle: settle, channels: idleChannels)
            } catch {
                print("  连带失败实验失败：\(error)")
            }
        }
    }

    // MARK: - #4 poll 边界取消

    /// 工作线程只能往盒子里记时间戳，主线程等信号后再算差值。
    final class TimingBox: @unchecked Sendable {
        var phase: String?
        var bytes: Int64?
        var loopExitAt: Date?
        var threadReturnAt: Date?
        var errorText: String?
    }

    static func measureCancellation(endpoint: SpikeProbe.Endpoint, path: String, chunk: Int,
                                    settle: Double, pollTimeoutMs: Int, waitMode: String,
                                    abort: Bool = false) throws {
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        let connection = ThroughputSpike.Connection(fd: fd, session: session)
        let flag = ThroughputSpike.CancelFlag()
        let parked = ThroughputSpike.CancelFlag()
        let counter = ThroughputSpike.Counter()
        let done = DispatchSemaphore(value: 0)

        let taskStart = Date()
        let box = TimingBox()

        DispatchQueue(label: "spike.cancel").async {
            do {
                try ThroughputSpike.runMultiplexed(connection: connection, path: path,
                                                   totalBytes: 64 * 1024 * 1024,
                                                   channels: 1, handlesPerChannel: 1,
                                                   chunk: chunk, counter: counter,
                                                   cancel: flag, pollTimeoutMs: pollTimeoutMs,
                                                   parked: parked, abortOnCancel: abort)
            } catch let cancellation as ThroughputSpike.Cancellation {
                box.phase = cancellation.phase
                box.bytes = cancellation.bytesSoFar
                box.loopExitAt = cancellation.exitAt
            } catch {
                box.errorText = "\(error)"
            }
            box.threadReturnAt = Date()
            done.signal()
        }

        // parked=true 时，建阶段（sftp_init + open，仍是阻塞调用）已经完成，
        // 循环真正停在 poll 边界上；这才是"200 ms 内取消"这条出口标准测的东西。
        var phase = "建阶段"
        if waitMode == "parked" {
            let deadline = taskStart.addingTimeInterval(30)
            while !parked.isSet, Date() < deadline { usleep(2_000) }
            phase = parked.isSet ? "poll边界" : "建阶段(未进入poll)"
            print(String(format: "  [poll=%5d ms] 建阶段耗时 %.0f ms，等待进入 poll：%@",
                         pollTimeoutMs, Date().timeIntervalSince(taskStart) * 1000, phase as NSString))
        } else {
            Thread.sleep(forTimeInterval: settle)
        }

        flag.request()
        let cancelAt = flag.setAt ?? Date()
        done.wait()

        // 三段分开计：取消→循环退出（这才该受 poll 切片约束）、
        // 循环退出→线程返回（关 handle/channel 的阻塞往返）、拆连接。
        let boundary = box.loopExitAt.map { $0.timeIntervalSince(cancelAt) * 1000 } ?? -1
        let cleanup = (box.threadReturnAt ?? cancelAt).timeIntervalSince(box.loopExitAt ?? cancelAt) * 1000
        let teardownStart = Date()
        if abort {
            // 设计里推荐的取消收尾：不发包、不等响应，直接掐 socket
            shutdown(fd, SHUT_RDWR)
            libssh2_session_free(session)
            close(fd)
        } else {
            SpikeProbe.shutdown(session: session, fd: fd)
        }
        let teardown = Date().timeIntervalSince(teardownStart) * 1000

        print(String(format: "  [poll=%5d ms] 取消→循环退出 %@ ms，清理(handle/channel) %7.1f ms，拆连接 %6.1f ms；%@ 已传 %d B；read调用=%d EAGAIN=%d poll=%d 超时=%d",
                     pollTimeoutMs,
                     (boundary < 0 ? "     —  " : String(format: "%8.1f", boundary)) as NSString,
                     cleanup, teardown,
                     (box.phase ?? "未取消") as NSString, Int(box.bytes ?? -1),
                     counter.calls, counter.eagain, counter.polls, counter.pollTimeouts))
        if let errorText = box.errorText { print("      \(errorText)") }
    }

    // MARK: - #5 阻塞调用只能靠 shutdown 打断

    static func measureBlockingInterrupt(endpoint: SpikeProbe.Endpoint, path: String,
                                         chunk: Int, settle: Double) throws {
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        let connection = ThroughputSpike.Connection(fd: fd, session: session)
        let counter = ThroughputSpike.Counter()
        let done = DispatchSemaphore(value: 0)

        let box = TimingBox()

        DispatchQueue(label: "spike.blocking").async {
            let start = Date()
            do {
                try ThroughputSpike.readRangeBlocking(connection: connection, path: path,
                                                      offset: 0, length: 8 * 1024 * 1024,
                                                      chunk: chunk, counter: counter)
                box.errorText = "没被打断，自己读完了（\(Int(Date().timeIntervalSince(start) * 1000)) ms）"
            } catch {
                box.errorText = "阻塞调用被打断返回：\(error)"
            }
            box.threadReturnAt = Date()
            done.signal()
        }

        Thread.sleep(forTimeInterval: settle)
        let shutdownStart = Date()
        let rc = shutdown(fd, SHUT_RDWR)
        let shutdownCall = Date().timeIntervalSince(shutdownStart) * 1000
        done.wait()
        let unblock = (box.threadReturnAt ?? shutdownStart).timeIntervalSince(shutdownStart) * 1000

        print("  shutdown(SHUT_RDWR) 本身 \(String(format: "%.3f", shutdownCall)) ms (rc=\(rc))")
        print("  阻塞调用从被打断到返回 \(String(format: "%.1f", unblock)) ms；\(box.errorText ?? "")")

        let teardownStart = Date()
        libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "spike interrupt", "")
        let disconnect = Date().timeIntervalSince(teardownStart) * 1000
        let freeStart = Date()
        libssh2_session_free(session)
        let free = Date().timeIntervalSince(freeStart) * 1000
        close(fd)
        print(String(format: "  打断后 disconnect %.1f ms，session_free %.1f ms", disconnect, free))
    }

    // MARK: - #5b 打断的连带损失：同 session 其他 channel

    /// 验收标准原文是"量化同 session 的其他 channel 一起失败的代价"。
    /// 这里先开 N 条空闲 channel，再让第 N+1 条卡在阻塞读里，然后 shutdown socket，
    /// 看空闲 channel 多久失败、能不能只损失那一条。
    static func measureCollateral(endpoint: SpikeProbe.Endpoint, path: String, chunk: Int,
                                  settle: Double, channels: Int) throws {
        let (fd, session) = try SpikeProbe.authenticatedSession(endpoint)
        let connection = ThroughputSpike.Connection(fd: fd, session: session)

        var sftps: [OpaquePointer] = []
        for _ in 0..<channels {
            guard let sftp = libssh2_sftp_init(session) else {
                throw ThroughputSpike.Failure(step: "sftp_init",
                                              detail: ThroughputSpike.lastSessionError(session))
            }
            sftps.append(sftp)
        }
        let aliveBefore = sftps.filter { probeStat($0, path) != nil }.count

        let counter = ThroughputSpike.Counter()
        let done = DispatchSemaphore(value: 0)
        let box = TimingBox()
        DispatchQueue(label: "spike.collateral").async {
            do {
                // readRangeBlocking 自己再开一条 channel，即"正在传数据的那条"
                try ThroughputSpike.readRangeBlocking(connection: connection, path: path,
                                                      offset: 0, length: 8 * 1024 * 1024,
                                                      chunk: chunk, counter: counter)
                box.errorText = "传输 channel 自己读完了"
            } catch {
                box.errorText = "传输 channel 被打断：\(error)"
            }
            box.threadReturnAt = Date()
            done.signal()
        }

        Thread.sleep(forTimeInterval: settle)
        let shutdownStart = Date()
        let rc = shutdown(fd, SHUT_RDWR)
        done.wait()
        let unblock = (box.threadReturnAt ?? shutdownStart).timeIntervalSince(shutdownStart) * 1000

        let probeStart = Date()
        let aliveAfter = sftps.dropFirst().filter { probeStat($0, path) != nil }.count
        let probeCost = Date().timeIntervalSince(probeStart) * 1000

        print(String(format: "  [%d 空闲channel] shutdown rc=%d，传输channel %6.1f ms 内返回；空闲channel 打断前可用 %d 个，打断后剩 %d 个，逐个探测共 %.1f ms",
                     channels, rc, unblock, aliveBefore, aliveAfter, probeCost))
        print("      \(box.errorText ?? "")")

        let teardownStart = Date()
        libssh2_session_free(session)
        let free = Date().timeIntervalSince(teardownStart) * 1000
        close(fd)
        print(String(format: "      直接 session_free（不发 disconnect）%.1f ms", free))
    }

    static func probeStat(_ sftp: OpaquePointer, _ path: String) -> Int64? {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = path.withCString { pointer in
            libssh2_sftp_stat_ex(sftp, pointer, UInt32(strlen(pointer)), LIBSSH2_SFTP_STAT, &attrs)
        }
        return rc == 0 ? Int64(attrs.filesize) : nil
    }
}
