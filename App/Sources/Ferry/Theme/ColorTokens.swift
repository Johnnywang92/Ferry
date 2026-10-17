import SwiftUI

/// 4 档强调色枚举（来自 UI-REFERENCE.md）
public enum FerryAccentOption: String, CaseIterable, Identifiable, Sendable {
    case teal = "Teal"
    case blue = "Blue"
    case green = "Green"
    case purple = "Purple"

    public var id: String { rawValue }

    public var hex: String {
        switch self {
        case .teal: return "#0F6E78"   // 默认
        case .blue: return "#1F5FB4"
        case .green: return "#3F6B3A"
        case .purple: return "#6B4BA8"
        }
    }

    public var color: Color {
        Color(hex: hex)
    }
}

/// 设计令牌调色板（UI-REFERENCE.md 逐值照抄）
public struct FerryTheme {
    public let isDark: Bool
    public let accent: FerryAccentOption

    public init(isDark: Bool, accent: FerryAccentOption = .teal) {
        self.isDark = isDark
        self.accent = accent
    }

    public var bg: Color { isDark ? Color(hex: "#1E2124") : Color(hex: "#FBFBFA") }
    public var bar: Color { isDark ? Color(hex: "#2A2D31") : Color(hex: "#F1F1EF") }
    public var barLine: Color { isDark ? Color(hex: "#101214") : Color(hex: "#DAD9D5") }
    public var side: Color { isDark ? Color(hex: "#25282C") : Color(hex: "#EDEDEA") }
    public var line: Color { isDark ? Color(hex: "#33373C") : Color(hex: "#E4E3DF") }
    public var panel: Color { isDark ? Color(hex: "#24272B") : Color(hex: "#F7F7F5") }
    public var text: Color { isDark ? Color(hex: "#ECEDEE") : Color(hex: "#1C2024") }
    public var text2: Color { isDark ? Color(hex: "#B7BCC2") : Color(hex: "#4A5056") }
    public var text3: Color { isDark ? Color(hex: "#A4AAB0") : Color(hex: "#5B6168") }
    public var field: Color { isDark ? Color(hex: "#2E3237") : Color(hex: "#F1F1EF") }
    public var segOn: Color { isDark ? Color(hex: "#4A4F55") : Color(hex: "#FFFFFF") }
    public var segOnText: Color { isDark ? Color(hex: "#FFFFFF") : Color(hex: "#1C2024") }
    public var btn: Color { isDark ? Color(hex: "#3A3F45") : Color(hex: "#FFFFFF") }
    public var btnRing: Color { isDark ? Color(hex: "#4C525A") : Color(hex: "#CFCEC9") }
    public var pill: Color { isDark ? Color(hex: "#2E3237") : Color(hex: "#FFFFFF") }
    public var pillRing: Color { isDark ? Color(hex: "#454B52") : Color(hex: "#D3D2CE") }
    public var barTrack: Color { isDark ? Color(hex: "#3A3F45") : Color(hex: "#E1E0DC") }
    public var icon: Color { isDark ? Color(hex: "#D8DBDE") : Color(hex: "#2B3036") }
    public var winRing: Color { isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.14) }
    public var tagLocal: Color { isDark ? Color(hex: "#5A6068") : Color(hex: "#4A5056") }

    public var accentColor: Color { accent.color }
    public var accentTint: Color { accent.color.opacity(isDark ? 0.35 : 0.15) }
    public var accentSelected: Color { accent.color }

    public var warningOrange: Color { Color(hex: "#F09A62") }
    public var errorRed: Color { isDark ? Color(hex: "#FF9C94") : Color(hex: "#D32F2F") }
    public var successGreen: Color { Color(hex: "#34C759") }
}

extension Color {
    public init(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("#") { cleanHex.removeFirst() }

        var intVal: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&intVal)

        let r, g, b, a: Double
        switch cleanHex.count {
        case 6: // RGB
            r = Double((intVal >> 16) & 0xFF) / 255.0
            g = Double((intVal >> 8) & 0xFF) / 255.0
            b = Double(intVal & 0xFF) / 255.0
            a = 1.0
        case 8: // RGBA
            r = Double((intVal >> 24) & 0xFF) / 255.0
            g = Double((intVal >> 16) & 0xFF) / 255.0
            b = Double((intVal >> 8) & 0xFF) / 255.0
            a = Double(intVal & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
