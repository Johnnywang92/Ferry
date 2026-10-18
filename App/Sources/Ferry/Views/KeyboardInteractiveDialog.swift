import FerryCore
import SwiftUI

public struct KeyboardInteractiveDialog: View {
    let request: KeyboardInteractiveRequest
    let onResponse: ([String]?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var answers: [String]

    private var theme: FerryTheme {
        ThemeManager.shared.theme(for: colorScheme)
    }

    public init(request: KeyboardInteractiveRequest, onResponse: @escaping ([String]?) -> Void) {
        self.request = request
        self.onResponse = onResponse
        self._answers = State(initialValue: Array(repeating: "", count: request.prompts.count))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 26))
                    .foregroundColor(theme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(request.name.isEmpty ? L10n.tr("键盘交互认证", "Keyboard-Interactive Authentication") : request.name)
                        .font(FerryFont.bodyBold)
                        .foregroundColor(theme.text)
                    if !request.instruction.isEmpty {
                        Text(request.instruction)
                            .font(FerryFont.caption)
                            .foregroundColor(theme.text2)
                    }
                }
            }

            Divider().background(theme.line)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<request.prompts.count, id: \.self) { idx in
                    let prompt = request.prompts[idx]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(FerryFont.captionMedium)
                            .foregroundColor(theme.text2)

                        if prompt.echo {
                            TextField("", text: $answers[idx])
                                .textFieldStyle(.roundedBorder)
                                .font(FerryFont.body)
                        } else {
                            SecureField("", text: $answers[idx])
                                .textFieldStyle(.roundedBorder)
                                .font(FerryFont.body)
                        }
                    }
                }
            }

            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    onResponse(nil)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("提交答案", "Submit")) {
                    onResponse(answers)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 440)
        .background(theme.bg)
    }
}
