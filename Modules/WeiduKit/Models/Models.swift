import Foundation

enum ListScope: Equatable, Hashable {
    case articles
    case starred
    case feed(String)

    var feedID: String? {
        if case .feed(let id) = self { return id }
        return nil
    }
}

struct Feed: Identifiable, Equatable {
    var id: String
    var url: String
    var title: String
    var siteURL: String
    var iconURL: String
    var category: String
    var sort: Int
    var addedAt: Date
    var lastFetchAt: Date?
    var lastError: String?
    var etag: String
    var lastModified: String
    var unreadCount: Int = 0
    var autoFulltext = false

    var host: String {
        if let host = URL(string: siteURL.isEmpty ? url : siteURL)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url
    }
}

struct Entry: Identifiable, Equatable {
    var id: String
    var feedID: String
    var feedTitle: String
    var title: String
    var url: String
    var author: String
    var summary: String
    var contentHTML: String
    var fulltextHTML: String?
    var imageURL: String
    var publishedAt: Date?
    var fetchedAt: Date
    var isRead: Bool
    var isStarred: Bool
    var opened: Bool
    var sortTime: Double

    var date: Date { publishedAt ?? fetchedAt }
    var displayTitle: String { title.isEmpty ? "无标题" : title }

    var readerSource: String {
        if let fulltextHTML, !fulltextHTML.isEmpty { return fulltextHTML }
        if !contentHTML.isEmpty { return contentHTML }
        return summary
    }

    var hasFulltext: Bool { fulltextHTML?.isEmpty == false }
}

struct ParsedEntry {
    var guid: String
    var title: String
    var url: String
    var author: String
    var summary: String
    var contentHTML: String
    var imageURL: String
    var publishedAt: Date?
}

struct DiscoveredFeed {
    var title: String
    var url: String
}

enum AppTab: String, Hashable {
    case articles
    case starred
    case feeds
    case settings
}

struct RecommendedFeed: Identifiable, Equatable {
    let title: String
    let url: String

    var id: String { url }
}

enum Recommendations {
    static let all: [RecommendedFeed] = [
        RecommendedFeed(title: "阮一峰的网络日志", url: "https://www.ruanyifeng.com/blog/atom.xml"),
        RecommendedFeed(title: "少数派", url: "https://sspai.com/feed"),
        RecommendedFeed(title: "Solidot 奇客", url: "https://www.solidot.org/index.rss"),
        RecommendedFeed(title: "酷壳 CoolShell", url: "https://coolshell.cn/feed"),
        RecommendedFeed(title: "云风的 BLOG", url: "https://blog.codingnow.com/atom.xml"),
        RecommendedFeed(title: "爱范儿", url: "https://www.ifanr.com/feed"),
        RecommendedFeed(title: "极客公园", url: "https://www.geekpark.net/rss"),
        RecommendedFeed(title: "机核 GCORES", url: "https://www.gcores.com/rss"),
        RecommendedFeed(title: "小众软件", url: "https://www.appinn.com/feed/"),
        RecommendedFeed(title: "IT之家", url: "https://www.ithome.com/rss/"),
        RecommendedFeed(title: "36氪", url: "https://36kr.com/feed"),
        RecommendedFeed(title: "Hacker News", url: "https://hnrss.org/frontpage"),
        RecommendedFeed(title: "Simon Willison's Weblog", url: "https://simonwillison.net/atom/everything/"),
        RecommendedFeed(title: "Julia Evans", url: "https://jvns.ca/atom.xml")
    ]
}

enum WeiduError: LocalizedError {
    case invalidURL
    case notAFeed
    case duplicateFeed
    case http(Int)
    case emptyFeed
    case network(String)
    case fulltextUnavailable
    case fulltextChallenged

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "地址无效"
        case .notAFeed: return "这个地址不是 RSS / Atom，也没找到订阅入口"
        case .duplicateFeed: return "已经订阅过这个源了"
        case .http(let code): return "服务器返回 \(code)"
        case .emptyFeed: return "订阅内容为空"
        case .network(let detail): return "网络错误：\(detail)"
        case .fulltextUnavailable: return "没能从页面里认出正文，可能是需要脚本加载的站点；可打开原文阅读"
        case .fulltextChallenged: return "站点返回了防爬验证页；可打开原文在浏览器里阅读"
        }
    }
}
