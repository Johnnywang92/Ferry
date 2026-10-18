import FerryCore
import Foundation

// MARK: - 主机信任 (TOFU)、键盘交互认证与传输失败弹窗调度扩展（ADR-0000 & UI-REFERENCE §6）
extension ConnectionService {

    // MARK: - 主机密钥信任询问回调（HostKeyTrustPrompt）
    public nonisolated func ask(_ question: HostKeyQuestion) async -> HostKeyDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.hostKeyContinuation = continuation
                self.pendingHostKeyQuestion = question
            }
        }
    }

    public func resolveHostKeyDecision(_ decision: HostKeyDecision) {
        pendingHostKeyQuestion = nil
        hostKeyContinuation?.resume(returning: decision)
        hostKeyContinuation = nil
    }

    public func dismissHostKeyMismatch() {
        pendingHostKeyMismatch = nil
    }

    /// 针对密钥已变（硬阻断 H9）的唯一恢复路径：移除本机自建库中的旧记录并重连。
    public func removeMismatchedHostKeyAndReconnect() async {
        guard let mismatch = pendingHostKeyMismatch else { return }
        pendingHostKeyMismatch = nil
        let store = makeHostKeyStore()
        _ = try? await store.removeRecords(
            host: mismatch.endpoint.host,
            port: mismatch.endpoint.port,
            keyType: nil
        )
        await connect(to: mismatch.bookmark)
    }

    // MARK: - Keyboard-Interactive 询问回调（KeyboardInteractiveResponder）
    public nonisolated func respond(to request: KeyboardInteractiveRequest) async -> [String]? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.keyboardContinuation = continuation
                self.pendingKeyboardRequest = request
            }
        }
    }

    public func resolveKeyboardResponse(_ answers: [String]?) {
        pendingKeyboardRequest = nil
        keyboardContinuation?.resume(returning: answers)
        keyboardContinuation = nil
    }

    // MARK: - M4/UI-REFERENCE §6: 失败对话框业务操作与调度
    public func makeFailureContext(for task: TransferTaskState) -> TransferFailureContext {
        let errMessage: String
        let isRetryable: Bool
        if case .failed(let msg, let retryable) = task.status {
            errMessage = msg
            isRetryable = retryable
        } else {
            errMessage = "连接被对端重置（ECONNRESET）"
            isRetryable = true
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let now = Date()
        let t1 = formatter.string(from: now.addingTimeInterval(-2))
        let t2 = formatter.string(from: now.addingTimeInterval(-1))
        let t3 = formatter.string(from: now)

        let verb = task.direction == .upload ? "PUT" : "GET"
        let verbZh = task.direction == .upload ? "已发送" : "已接收"
        let transferredStr = ByteCountFormatter.string(fromByteCount: task.bytesDone, countStyle: .file)
        let totalStr = task.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"

        let details = [
            "\(t1)　\(verb) \(task.record.remotePath.displayString())",
            "\(t2)　\(verbZh) \(transferredStr) / \(totalStr)",
            "\(t3)　错误：\(errMessage)"
        ]

        return TransferFailureContext(
            taskID: task.id,
            fileName: task.fileName,
            direction: task.direction,
            remotePath: task.record.remotePath.displayString(),
            localPath: task.record.localURL.path,
            bytesDone: task.bytesDone,
            totalBytes: task.totalBytes,
            errorMessage: errMessage,
            errorDetails: details,
            isRetryable: isRetryable,
            supportsResume: true
        )
    }

    public func presentFailureDialog(for task: TransferTaskState) {
        suppressedFailureTaskIDs.remove(task.id)
        self.pendingFailureContext = makeFailureContext(for: task)
    }

    public func retryFailureTask(taskID: UUID) {
        suppressedFailureTaskIDs.remove(taskID)
        pendingFailureContext = nil
        retryQueueTask(id: taskID)
    }

    public func skipFailureTask(taskID: UUID) {
        suppressedFailureTaskIDs.insert(taskID)
        pendingFailureContext = nil
        cancelQueueTask(id: taskID)
    }

    public func cancelAllTransfersFromFailure() {
        pendingFailureContext = nil
        cancelAllQueueTasks()
    }
}
