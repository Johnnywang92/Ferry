import CryptoKit
import FerryCore
import SwiftUI

public struct HostKeyPromptDialog: View {
    let question: HostKeyQuestion
    let onDecision: (HostKeyDecision) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var alsoWriteToKnownHosts = false

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    private var fingerprint: String {
        let hash = SHA256.hash(data: question.hostKey.blob)
        return "SHA256:" + Data(hash).base64EncodedString()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 28))
                    .foregroundColor(theme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("无法验证主机真实性", "Authenticity of Host Cannot Be Established"))
                        .font(FerryFont.bodyBold)
                        .foregroundColor(theme.text)
                    Text(L10n.tr("首次连接到此服务器，或服务器的主机密钥类型已变更。", "Connecting to this host for the first time, or host key type changed."))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }
            }

            Divider().background(theme.line)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: L10n.tr("主机目标", "Endpoint"), value: question.endpoint.displayString)
                infoRow(label: L10n.tr("密钥类型", "Key Type"), value: "\(question.hostKey.wireType) (\(question.hostKey.algorithm))")
                infoRow(label: L10n.tr("密钥指纹", "Fingerprint"), value: fingerprint, isMono: true)

                switch question.reason {
                case .unknownHost:
                    infoRow(label: L10n.tr("判定原因", "Reason"), value: L10n.tr("在 known_hosts 中未找到该主机的任何记录（TOFU 首次信任）", "No record in known_hosts (TOFU trust on first use)"))
                case .hostKnownWithOtherAlgorithms(let knownTypes, let source):
                    infoRow(label: L10n.tr("判定原因", "Reason"), value: L10n.format("主机已知，但此前记录的算法为 [%@]（来源：%@）", "Host known with [%@] (source: %@)", knownTypes.joined(separator: ", "), source))
                case .certificateOnly(let source):
                    infoRow(label: L10n.tr("判定原因", "Reason"), value: L10n.format("表里仅有证书行，线路未呈上对应证书（来源：%@）", "Certificate-only lines found, raw key presented (source: %@)", source))
                }
            }
            .padding(12)
            .background(theme.field)
            .cornerRadius(FerryRadius.r6)

            Toggle(isOn: $alsoWriteToKnownHosts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("同时追加写入系统的 ~/.ssh/known_hosts", "Append to system ~/.ssh/known_hosts as well"))
                        .font(FerryFont.subheadlineMedium)
                        .foregroundColor(theme.text)
                    Text(L10n.tr("勾选后，终端中的 ssh 命令将能够共享信任此密钥；不勾选则仅由 Ferry 独立记录。", "When checked, terminal ssh commands will trust this key. Otherwise, trusted only by Ferry."))
                        .font(FerryFont.micro)
                        .foregroundColor(theme.text3)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)

            HStack {
                Button(L10n.tr("拒绝并取消", "Decline & Cancel")) {
                    onDecision(.decline)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("信任并继续连接", "Trust & Connect")) {
                    if alsoWriteToKnownHosts {
                        onDecision(.acceptAndWriteKnownHosts)
                    } else {
                        onDecision(.accept)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 520)
        .background(theme.bg)
    }

    private func infoRow(label: String, value: String, isMono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + "：")
                .font(FerryFont.captionMedium)
                .foregroundColor(theme.text3)
                .frame(width: 72, alignment: .trailing)

            Text(value)
                .font(isMono ? FerryFont.monoCaption : FerryFont.caption)
                .foregroundColor(theme.text)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

/// 主机密钥已变更硬阻断警告对话框（ADR-0000 §11 H9：不可一键忽略跳过，唯一恢复路径是移除旧记录后重新走 TOFU）。
public struct HostKeyMismatchDialog: View {
    let alert: HostKeyMismatchAlert
    let onDismiss: () -> Void
    let onRemoveAndReconnect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 30))
                    .foregroundColor(theme.errorRed)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("严重安全警告：远程主机密钥已变更！", "SECURITY WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"))
                        .font(FerryFont.bodyBold)
                        .foregroundColor(theme.errorRed)
                    Text(L10n.tr("连接已被硬阻断。这可能意味着正在遭受中间人攻击（MITM），或管理员刚刚重装/轮换了服务器密钥。", "Connection blocked. Someone could be eavesdropping on you right now (MITM), or the administrator just rotated the key."))
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }
            }

            Divider().background(theme.line)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(L10n.tr("目标主机：", "Target Host:"))
                        .font(FerryFont.captionMedium)
                        .foregroundColor(theme.text3)
                        .frame(width: 76, alignment: .trailing)
                    Text(alert.endpoint.displayString)
                        .font(FerryFont.monoCaption)
                        .foregroundColor(theme.text)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(L10n.tr("新密钥指纹：", "New Fingerprint:"))
                        .font(FerryFont.captionMedium)
                        .foregroundColor(theme.text3)
                        .frame(width: 76, alignment: .trailing)
                    Text(alert.newFingerprint)
                        .font(FerryFont.monoCaption)
                        .foregroundColor(theme.errorRed)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(theme.field)
            .cornerRadius(FerryRadius.r6)

            Text(L10n.tr("根据 TOFU 安全基线，Ferry 不允许在不验证的情况下直接跳过密钥不匹配。若你已与服务器管理员核实此次密钥轮换属实，可移除 Ferry 已知主机库中的旧记录并重新发起连接。", "Under TOFU security policy, Ferry does not allow bypassing mismatched host keys. If verified with the administrator, remove the stale host key record and reconnect."))
                .font(FerryFont.micro)
                .foregroundColor(theme.text3)

            HStack {
                Button(L10n.tr("移除旧主机记录并重新连接…", "Remove Old Key & Reconnect…"), role: .destructive) {
                    onRemoveAndReconnect()
                }

                Spacer()

                Button(L10n.tr("保持断开", "Stay Disconnected")) {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 540)
        .background(theme.bg)
    }
}
