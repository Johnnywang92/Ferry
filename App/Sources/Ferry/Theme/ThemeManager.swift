import SwiftUI

/// 视觉外观模式选项
public enum FerryAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "跟随系统"
    case light = "浅色模式"
    case dark = "深色模式"

    public var id: String { rawValue }

    @MainActor
    public var displayName: String {
        switch self {
        case .auto: return L10n.tr("跟随系统", "System")
        case .light: return L10n.tr("浅色模式", "Light")
        case .dark: return L10n.tr("深色模式", "Dark")
        }
    }
}

@Observable
@MainActor
public final class ThemeManager {
    public static let shared = ThemeManager()

    private static let appearanceKey = "dev.ferry.app.appearanceMode"
    private static let accentKey = "dev.ferry.app.accentOption"
    private static let showHiddenKey = "dev.ferry.app.showHiddenFiles"

    public var appearanceMode: FerryAppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceKey)
        }
    }

    public var accentOption: FerryAccentOption {
        didSet {
            UserDefaults.standard.set(accentOption.rawValue, forKey: Self.accentKey)
        }
    }

    /// 隐藏文件显示开关（v2.3 §356：服务器上 `.env`、`.git`、`.htaccess` 是刚需，默认显示）。
    public var showHiddenFiles: Bool {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: Self.showHiddenKey)
        }
    }

    private static let autoRetryKey = "dev.ferry.app.autoRetryFailures"

    /// 遇到传输失败时是否默认勾选自动重试（UI-REFERENCE.md §6）。
    public var autoRetryFailures: Bool {
        didSet {
            UserDefaults.standard.set(autoRetryFailures, forKey: Self.autoRetryKey)
        }
    }

    public init() {
        if let rawAppearance = UserDefaults.standard.string(forKey: Self.appearanceKey),
           let mode = FerryAppearanceMode(rawValue: rawAppearance) {
            self.appearanceMode = mode
        } else {
            self.appearanceMode = .auto
        }

        if let rawAccent = UserDefaults.standard.string(forKey: Self.accentKey),
           let accent = FerryAccentOption(rawValue: rawAccent) {
            self.accentOption = accent
        } else {
            self.accentOption = .teal
        }

        if UserDefaults.standard.object(forKey: Self.showHiddenKey) != nil {
            self.showHiddenFiles = UserDefaults.standard.bool(forKey: Self.showHiddenKey)
        } else {
            self.showHiddenFiles = true
        }

        if UserDefaults.standard.object(forKey: Self.autoRetryKey) != nil {
            self.autoRetryFailures = UserDefaults.standard.bool(forKey: Self.autoRetryKey)
        } else {
            self.autoRetryFailures = true
        }
    }

    public func theme(for colorScheme: ColorScheme) -> FerryTheme {
        let isDark: Bool
        switch appearanceMode {
        case .auto:
            isDark = (colorScheme == .dark)
        case .light:
            isDark = false
        case .dark:
            isDark = true
        }
        return FerryTheme(isDark: isDark, accent: accentOption)
    }

    public var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    public func toggleHiddenFiles() {
        showHiddenFiles.toggle()
    }
}
