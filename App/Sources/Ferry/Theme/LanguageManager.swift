import Foundation
import Observation
import SwiftUI

/// 支持的界面语言选项
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zh = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    @MainActor
    public var displayName: String {
        switch self {
        case .system:
            return LanguageManager.shared.isEnglish ? "System Default" : "跟随系统"
        case .zh:
            return "简体中文"
        case .en:
            return "English"
        }
    }
}

/// 界面语言管理单例（Swift 6 严格并发与 @Observable 响应式架构）
@Observable
@MainActor
public final class LanguageManager {
    public static let shared = LanguageManager()

    private static let languageKey = "dev.ferry.app.language"

    public var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: Self.languageKey)
        }
    }

    /// 当前实际呈现是否为英文
    public var isEnglish: Bool {
        switch currentLanguage {
        case .en:
            return true
        case .zh:
            return false
        case .system:
            if let preferred = Locale.preferredLanguages.first {
                return !preferred.hasPrefix("zh")
            }
            return false
        }
    }

    public init() {
        if let raw = UserDefaults.standard.string(forKey: Self.languageKey),
           let lang = AppLanguage(rawValue: raw) {
            self.currentLanguage = lang
        } else {
            self.currentLanguage = .system
        }
    }

    public func setLanguage(_ language: AppLanguage) {
        self.currentLanguage = language
    }
}

/// 双语本地化文本转换工具
public struct L10n {
    @MainActor
    public static func tr(_ zh: String, _ en: String) -> String {
        LanguageManager.shared.isEnglish ? en : zh
    }

    @MainActor
    public static func format(_ zh: String, _ en: String, _ arguments: CVarArg...) -> String {
        let format = LanguageManager.shared.isEnglish ? en : zh
        return String(format: format, arguments: arguments)
    }
}
