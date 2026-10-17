import SwiftUI

/// 视觉外观模式选项
public enum FerryAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "跟随系统"
    case light = "浅色模式"
    case dark = "深色模式"

    public var id: String { rawValue }
}

@Observable
@MainActor
public final class ThemeManager {
    public var appearanceMode: FerryAppearanceMode = .auto
    public var accentOption: FerryAccentOption = .teal

    public init() {}

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
}
