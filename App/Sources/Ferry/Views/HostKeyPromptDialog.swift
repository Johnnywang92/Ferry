import CryptoKit
import FerryCore
import SwiftUI

public struct HostKeyPromptDialog: View {
    let question: HostKeyQuestion
    let onDecision: (HostKeyDecision) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var alsoWriteToKnownHosts = false

    private var theme: FerryTheme {
        ThemeManager().theme(for: colorScheme)
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
                    Text("无法验证主机真实性")
                        .font(FerryFont.bodyBold)
                        .foregroundColor(theme.text)
                    Text("首次连接到此服务器，或服务器的主机密钥类型已变更。")
                        .font(FerryFont.caption)
                        .foregroundColor(theme.text2)
                }
            }

            Divider().background(theme.line)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "主机目标", value: question.endpoint.displayString)
                infoRow(label: "密钥类型", value: question.hostKey.algorithm)
                infoRow(label: "密钥指纹", value: fingerprint, isMono: true)

                switch question.reason {
                case .unknownHost:
                    infoRow(label: "判定原因", value: "在 known_hosts 中未找到该主机的任何记录（TOFU 首次信任）")
                case .hostKnownWithOtherAlgorithms(let knownTypes, let source):
                    infoRow(label: "判定原因", value: "主机已知，但此前记录的算法为 [\(knownTypes.joined(separator: ", "))]（来源：\(source)）")
                case .certificateOnly(let source):
                    infoRow(label: "判定原因", value: "表里仅有证书行，线路未呈上对应证书（来源：\(source)）")
                }
            }
            .padding(12)
            .background(theme.field)
            .cornerRadius(FerryRadius.r6)

            Toggle(isOn: $alsoWriteToKnownHosts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同时追加写入系统的 ~/.ssh/known_hosts")
                        .font(FerryFont.subheadlineMedium)
                        .foregroundColor(theme.text)
                    Text("勾选后，终端中的 ssh 命令将能够共享信任此密钥；不勾选则仅由 Ferry 独立记录。")
                        .font(FerryFont.micro)
                        .foregroundColor(theme.text3)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)

            HStack {
                Button("拒绝并取消") {
                    onDecision(.decline)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("信任并继续连接") {
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
