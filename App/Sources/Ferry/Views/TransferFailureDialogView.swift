import FerryCore
import SwiftUI

/// 传输失败独立弹窗与倒计时重试对话框（UI-REFERENCE.md §6 & Ferry.html 第 5 屏）。
public struct TransferFailureDialogView: View {
    let context: TransferFailureContext
    let onRetry: () -> Void
    let onSkip: () -> Void
    let onCancelAll: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var themeManager: ThemeManager { ThemeManager.shared }
    private var theme: FerryTheme { themeManager.theme(for: colorScheme) }

    @State private var autoRetryChecked: Bool
    @State private var countdownSeconds: Int = 5
    @State private var isCountdownActive: Bool = true
    @State private var isDetailsExpanded: Bool = true

    public init(
        context: TransferFailureContext,
        onRetry: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onCancelAll: @escaping () -> Void
    ) {
        self.context = context
        self.onRetry = onRetry
        self.onSkip = onSkip
        self.onCancelAll = onCancelAll
        self._autoRetryChecked = State(initialValue: ThemeManager.shared.autoRetryFailures)
    }

    private var transferredFormatted: String {
        ByteCountFormatter.string(fromByteCount: context.bytesDone, countStyle: .file)
    }

    private var totalFormatted: String {
        if let total = context.totalBytes, total > 0 {
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
        return L10n.tr("未知", "Unknown")
    }

    private var percentageString: String {
        guard let total = context.totalBytes, total > 0 else { return "0%" }
        let pct = Int(min(max(Double(context.bytesDone) / Double(total), 0), 1.0) * 100)
        return "\(pct)%"
    }

    private var titleText: String {
        if context.direction == .upload {
            return L10n.format("“%@”上传失败", "\"%@\" Upload Failed", context.fileName)
        } else {
            return L10n.format("“%@”下载失败", "\"%@\" Download Failed", context.fileName)
        }
    }

    private var subtitleText: String {
        L10n.format(
            "传输过程中，服务器断开了连接。已传输 %@ / %@（%@）。",
            "The server disconnected during transfer. Transferred %@ / %@ (%@).",
            transferredFormatted,
            totalFormatted,
            percentageString
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 头部：红色感叹号圆标 + 标题与简要说明（padding: 24 28 10, gap 16）
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(theme.errorRed)
                        .frame(width: 44, height: 44)

                    Image(systemName: "exclamationmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(theme.text)
                        .lineLimit(1)

                    Text(subtitleText)
                        .font(.system(size: 13))
                        .foregroundColor(theme.text2)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .padding(.horizontal, 28)
            .padding(.bottom, 10)

            // 详细信息面板（padding: 8 28 4）
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDetailsExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Text(L10n.tr("详细信息", "Details"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.text2)

                        Image(systemName: isDetailsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.text3)
                    }
                }
                .buttonStyle(.plain)

                if isDetailsExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(context.errorDetails, id: \.self) { line in
                            if line.contains("错误") || line.contains("Error") {
                                Text(line)
                                    .font(FerryFont.monoSmall)
                                    .foregroundColor(theme.errorRed)
                                    .fontWeight(.semibold)
                            } else {
                                Text(line)
                                    .font(FerryFont.monoSmall)
                                    .foregroundColor(theme.text)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.field)
                    .cornerRadius(FerryRadius.r8)
                    .overlay(
                        RoundedRectangle(cornerRadius: FerryRadius.r8)
                            .stroke(theme.line, lineWidth: 1)
                    )
                }

                if context.supportsResume {
                    Text(L10n.format(
                        "服务器支持断点续传，重试时会从 %@ 处继续，不会从头开始。",
                        "The server supports resume. Retrying will continue from %@ without restarting.",
                        transferredFormatted
                    ))
                    .font(.system(size: 13))
                    .foregroundColor(theme.text2)
                    .lineSpacing(3)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)

            // 自动重试复选框（padding: 10 28 18）
            HStack(spacing: 8) {
                Toggle(isOn: $autoRetryChecked) {
                    Text(L10n.tr("以后遇到失败，自动重试 3 次（间隔 5 秒）", "Auto-retry 3 times upon failure (5s interval)"))
                        .font(.system(size: 13))
                        .foregroundColor(theme.text)
                }
                .toggleStyle(.checkbox)
                .onChange(of: autoRetryChecked) { _, newValue in
                    themeManager.autoRetryFailures = newValue
                    if !newValue {
                        isCountdownActive = false
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 18)

            // 底部按钮栏（padding: 14 28，border-top: 1px line）
            HStack {
                Button(L10n.tr("取消全部传输", "Cancel All Transfers")) {
                    isCountdownActive = false
                    onCancelAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.errorRed)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(theme.btn)
                .cornerRadius(FerryRadius.r7)
                .overlay(
                    RoundedRectangle(cornerRadius: FerryRadius.r7)
                        .stroke(theme.btnRing, lineWidth: 1)
                )

                Spacer()

                HStack(spacing: 10) {
                    Button(L10n.tr("跳过此文件", "Skip This File")) {
                        isCountdownActive = false
                        onSkip()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.text)
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background(theme.btn)
                    .cornerRadius(FerryRadius.r7)
                    .overlay(
                        RoundedRectangle(cornerRadius: FerryRadius.r7)
                            .stroke(theme.btnRing, lineWidth: 1)
                    )

                    Button(action: {
                        isCountdownActive = false
                        onRetry()
                    }) {
                        Text(retryButtonTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 22)
                            .frame(height: 32)
                            .background(theme.accentColor)
                            .cornerRadius(FerryRadius.r7)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(theme.bar)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(theme.line),
                alignment: .top
            )
        }
        .frame(width: 520)
        .background(theme.bg)
        .cornerRadius(FerryRadius.r12)
        .overlay(
            RoundedRectangle(cornerRadius: FerryRadius.r12)
                .stroke(theme.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 30, x: 0, y: 15)
        .task(id: isCountdownActive && autoRetryChecked) {
            guard isCountdownActive && autoRetryChecked else { return }
            while isCountdownActive && autoRetryChecked && countdownSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard isCountdownActive && autoRetryChecked else { break }
                countdownSeconds -= 1
            }
            if !Task.isCancelled && isCountdownActive && autoRetryChecked && countdownSeconds <= 0 {
                isCountdownActive = false
                onRetry()
            }
        }
    }

    private var retryButtonTitle: String {
        if isCountdownActive && autoRetryChecked && countdownSeconds > 0 {
            return L10n.format("重试 (%d秒)", "Retry (%ds)", countdownSeconds)
        }
        return L10n.tr("重试", "Retry")
    }
}
