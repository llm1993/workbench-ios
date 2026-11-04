import SwiftUI
import UIKit

enum AccentTheme: String, CaseIterable, Identifiable, Codable {
    case green, blue, indigo, amber, rose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .green: return "青绿"
        case .blue: return "海蓝"
        case .indigo: return "靛紫"
        case .amber: return "琥珀"
        case .rose: return "胭脂"
        }
    }

    var lightHex: UInt32 {
        switch self {
        case .green: return 0x386A57
        case .blue: return 0x2E5F8A
        case .indigo: return 0x565083
        case .amber: return 0x94601F
        case .rose: return 0x8F4A5B
        }
    }

    var darkHex: UInt32 {
        switch self {
        case .green: return 0x9BC8AF
        case .blue: return 0x9CC4E4
        case .indigo: return 0xBDB7E6
        case .amber: return 0xE2B27E
        case .rose: return 0xE3A8B4
        }
    }

    var softLightHex: UInt32 {
        switch self {
        case .green: return 0xE8EFE9
        case .blue: return 0xE7EEF5
        case .indigo: return 0xECEBF5
        case .amber: return 0xF4EDE2
        case .rose: return 0xF4E8EB
        }
    }

    var softDarkHex: UInt32 {
        switch self {
        case .green: return 0x263B31
        case .blue: return 0x24313C
        case .indigo: return 0x2B283E
        case .amber: return 0x3A2F22
        case .rose: return 0x3A282D
        }
    }

    var color: Color { Color.dynamic(light: lightHex, dark: darkHex) }
    var softColor: Color { Color.dynamic(light: softLightHex, dark: softDarkHex) }

    var lightCSS: String { Self.css(lightHex) }
    var darkCSS: String { Self.css(darkHex) }
    var selectionLightCSS: String { Self.rgba(lightHex, alpha: 0.20) }
    var selectionDarkCSS: String { Self.rgba(darkHex, alpha: 0.22) }

    private static func css(_ hex: UInt32) -> String { String(format: "#%06x", hex) }

    private static func rgba(_ hex: UInt32, alpha: Double) -> String {
        "rgba(\((hex >> 16) & 0xFF),\((hex >> 8) & 0xFF),\(hex & 0xFF),\(alpha))"
    }
}

enum Theme {
    static var accentTheme: AccentTheme = .green

    static var accent: Color { accentTheme.color }
    static var accentSoft: Color { accentTheme.softColor }
    static let onAccent = Color.dynamic(light: 0xFFFFFF, dark: 0x151816)
    static let star = Color.dynamic(light: 0xB8862B, dark: 0xE0B24D)
    static let background = Color.dynamic(light: 0xF5F5F1, dark: 0x151816)
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1C201D)
    static let surface2 = Color.dynamic(light: 0xEFEFEA, dark: 0x252B26)
    static let text = Color.dynamic(light: 0x242B26, dark: 0xE8ECE7)
    static let text2 = Color.dynamic(light: 0x667060, dark: 0xADB6AB)
    static let text3 = Color.dynamic(light: 0x697363, dark: 0x8B968A)
    static let line = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.09)
    static let lineStrong = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.16)
}

extension Color {
    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: Double(alpha)
        )
    }

    static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
