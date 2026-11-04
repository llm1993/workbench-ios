import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ReadingFont: String, CaseIterable, Identifiable, Codable {
    case serif, sans

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: return "宋体"
        case .sans: return "黑体"
        }
    }
}

enum ArticleListStyle: String, CaseIterable, Identifiable, Codable {
    case card, plain

    var id: String { rawValue }
    var label: String { self == .card ? "卡片" : "平铺" }
}

enum ListDensity: String, CaseIterable, Identifiable, Codable {
    case compact, normal, expansive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "紧凑"
        case .normal: return "标准"
        case .expansive: return "宽松"
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: return 10
        case .normal: return 14
        case .expansive: return 18
        }
    }

    var thumbnailSize: CGFloat { self == .expansive ? 96 : 74 }
}

enum UnreadFilter: String, CaseIterable, Identifiable, Codable {
    case unread, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unread: return "未读"
        case .all: return "全部"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var theme: AppTheme = .system
    var accent: AccentTheme = .green
    var readingFont: ReadingFont = .serif
    var readingSize: Int = 18
    var readingMargin: Int = 24
    var listFontSize: Int = 16
    var listStyle: ArticleListStyle = .card
    var density: ListDensity = .normal
    var imagesInList = true
    var showSummary = true
    var markReadOnOpen = true
    var autoReadOnScroll = false
    var cacheCleanupDays = 0
    var listView: UnreadFilter = .unread
    var refreshMinutes = 60
    var keepDays = 30
    var openInBrowser = true

    var listShowsSummary: Bool { showSummary && density != .compact }
    var listShowsImages: Bool { imagesInList && density != .compact }
    var listTitleSize: CGFloat { CGFloat(listFontSize) + (density == .expansive ? 1 : -0.5) }

    static let readingSizes = [16, 18, 20, 23]
    static let readingMargins = [12, 18, 24, 32]
    static let listFontSizes = [14, 15, 16, 18]
    static let refreshChoices = [0, 15, 30, 60, 120]
    static let keepChoices = [0, 7, 30, 90]
    static let cacheCleanupChoices = [0, 1, 7, 30]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case theme, accent, readingFont, readingSize, readingMargin, listFontSize, listStyle, density, imagesInList
        case showSummary, markReadOnOpen, listView, refreshMinutes, keepDays
        case autoReadOnScroll, cacheCleanupDays, openInBrowser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        accent = try c.decodeIfPresent(AccentTheme.self, forKey: .accent) ?? .green
        readingFont = try c.decodeIfPresent(ReadingFont.self, forKey: .readingFont) ?? .serif
        readingSize = try c.decodeIfPresent(Int.self, forKey: .readingSize) ?? 18
        let margin = try c.decodeIfPresent(Int.self, forKey: .readingMargin) ?? 24
        readingMargin = Self.readingMargins.contains(margin) ? margin : 24
        let listSize = try c.decodeIfPresent(Int.self, forKey: .listFontSize) ?? 16
        listFontSize = Self.listFontSizes.contains(listSize) ? listSize : 16
        let style = try c.decodeIfPresent(String.self, forKey: .listStyle)
        listStyle = ArticleListStyle(rawValue: style ?? "") ?? .card
        density = try c.decodeIfPresent(ListDensity.self, forKey: .density) ?? .normal
        imagesInList = try c.decodeIfPresent(Bool.self, forKey: .imagesInList) ?? true
        showSummary = try c.decodeIfPresent(Bool.self, forKey: .showSummary) ?? true
        markReadOnOpen = try c.decodeIfPresent(Bool.self, forKey: .markReadOnOpen) ?? true
        autoReadOnScroll = try c.decodeIfPresent(Bool.self, forKey: .autoReadOnScroll) ?? false
        let cleanup = try c.decodeIfPresent(Int.self, forKey: .cacheCleanupDays) ?? 0
        cacheCleanupDays = Self.cacheCleanupChoices.contains(cleanup) ? cleanup : 0
        listView = try c.decodeIfPresent(UnreadFilter.self, forKey: .listView) ?? .unread
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 60
        keepDays = try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? 30
        openInBrowser = try c.decodeIfPresent(Bool.self, forKey: .openInBrowser) ?? true
    }

    func saved() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: SettingsStorage.key)
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: SettingsStorage.key),
              let value = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return value
    }

    var refreshLabel: String {
        refreshMinutes == 0 ? "手动" : (refreshMinutes >= 60 ? "\(refreshMinutes / 60) 小时" : "\(refreshMinutes) 分钟")
    }

    var keepLabel: String {
        keepDays == 0 ? "永久" : "\(keepDays) 天"
    }
}

private enum SettingsStorage {
    static let key = "weidu.settings.v1"
}
