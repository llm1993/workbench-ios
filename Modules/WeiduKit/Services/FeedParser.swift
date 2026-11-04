import Foundation
import SwiftSoup

struct ParsedFeed {
    var title: String
    var siteURL: String
    var entries: [ParsedEntry]
}

final class FeedParser: NSObject, XMLParserDelegate {
    private struct Item {
        var title = ""
        var link = ""
        var guid = ""
        var summary = ""
        var content = ""
        var author = ""
        var enclosure = ""
        var media = ""
        var published = ""
        var updated = ""
    }

    private let data: Data
    private var elements: [String] = []
    private var buffer = ""
    private var inItem = false
    private var current = Item()
    private var items: [Item] = []
    private var feedTitle = ""
    private var feedSiteURL = ""
    private var failed = false

    init(data: Data) {
        self.data = data
    }

    func parse() throws -> ParsedFeed {
        guard !data.isEmpty else { throw WeiduError.emptyFeed }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !failed else {
            if let error = parser.parserError {
                throw WeiduError.network("解析订阅失败（\(error.localizedDescription)）")
            }
            throw WeiduError.notAFeed
        }
        let parsed = items.compactMap(makeEntry)
        guard !parsed.isEmpty else { throw WeiduError.emptyFeed }
        return ParsedFeed(title: cleanText(feedTitle), siteURL: feedSiteURL, entries: parsed)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elements.append(elementName)
        buffer = ""
        let name = elementName.lowercased()

        if !inItem {
            if name == "item" || name == "entry" {
                inItem = true
                current = Item()
                return
            }
            if name == "link" {
                let rel = attributeDict["rel"]?.lowercased() ?? "alternate"
                if (rel == "alternate" || rel.isEmpty), feedSiteURL.isEmpty, let href = attributeDict["href"] {
                    feedSiteURL = href
                }
            }
            return
        }

        switch name {
        case "link":
            let rel = attributeDict["rel"]?.lowercased() ?? "alternate"
            if (rel == "alternate" || rel.isEmpty), current.link.isEmpty, let href = attributeDict["href"] {
                current.link = href
            }
        case "enclosure":
            if current.enclosure.isEmpty, let url = attributeDict["url"] {
                current.enclosure = url
            }
        case "media:content", "media:thumbnail":
            if current.media.isEmpty, let url = attributeDict["url"] {
                current.media = url
            }
        case "guid":
            if let permalink = attributeDict["isPermaLink"], permalink.lowercased() == "false" {
                current.guid = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) {
            buffer += value
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = elementName.lowercased()
        let parent = elements.count >= 2 ? elements[elements.count - 2].lowercased() : ""
        elements.removeLast()
        buffer = ""

        if !inItem {
            if name == "title", feedTitle.isEmpty, !value.isEmpty {
                feedTitle = value
            } else if name == "link", feedSiteURL.isEmpty, !value.isEmpty {
                feedSiteURL = value
            }
            return
        }

        switch name {
        case "item", "entry":
            items.append(current)
            inItem = false
        case "title":
            if current.title.isEmpty { current.title = value }
        case "link":
            if current.link.isEmpty { current.link = value }
        case "guid", "id":
            if current.guid.isEmpty { current.guid = value }
        case "description", "summary":
            if current.summary.isEmpty { current.summary = value }
        case "content:encoded", "content":
            if current.content.isEmpty { current.content = value }
        case "pubdate", "published", "dc:date", "date":
            if current.published.isEmpty { current.published = value }
        case "updated":
            if current.updated.isEmpty { current.updated = value }
        case "dc:creator":
            if current.author.isEmpty { current.author = value }
        case "author":
            if current.author.isEmpty, !value.isEmpty { current.author = value }
        case "name":
            if parent == "author", current.author.isEmpty { current.author = value }
        default:
            break
        }
    }

    // MARK: - 组装

    private func makeEntry(_ item: Item) -> ParsedEntry? {
        let link = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
        var guid = item.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if guid.isEmpty { guid = link }
        let rawTitle = item.title
        let title = cleanText(rawTitle)
        if guid.isEmpty {
            guid = title + "|" + item.published + "|" + item.updated
        }
        guard !guid.isEmpty else { return nil }

        let rawContent = item.content.isEmpty ? item.summary : item.content
        let base = link.isEmpty ? feedSiteURL : link
        let contentHTML = makeHTML(rawContent)
        let summary = shorten(cleanText(stripHTML(rawContent)), limit: 600)
        let date = DateParsing.parse(item.published) ?? DateParsing.parse(item.updated)

        var image = item.enclosure.isEmpty ? item.media : item.enclosure
        if image.isEmpty {
            image = firstImage(in: rawContent, base: base)
        }
        if !image.isEmpty {
            image = absoluteURL(image, base: base)
        }

        return ParsedEntry(
            guid: guid,
            title: title,
            url: link.isEmpty ? feedSiteURL : link,
            author: cleanText(item.author),
            summary: summary,
            contentHTML: contentHTML,
            imageURL: image,
            publishedAt: date
        )
    }

    private func stripHTML(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return html }
        return (try? doc.text()) ?? html
    }

    private func cleanText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<") || trimmed.contains("&") else { return trimmed }
        guard let doc = try? SwiftSoup.parse(trimmed) else { return trimmed }
        let value = (try? doc.text()) ?? trimmed
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeHTML(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("<") { return trimmed }
        let escaped = Format.escapeHTML(trimmed).replacingOccurrences(of: "\n", with: "<br>")
        return "<p>\(escaped)</p>"
    }

    private func firstImage(in html: String, base: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        guard let img = try? doc.select("img").first() else { return "" }
        for attr in ["src", "data-src", "data-original", "data-lazy-src"] {
            if let value = try? img.attr(attr), !value.isEmpty {
                return absoluteURL(value, base: base)
            }
        }
        return ""
    }

    private func absoluteURL(_ raw: String, base: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        if value.hasPrefix("//") { return "https:" + value }
        guard let baseURL = URL(string: base), let url = URL(string: value, relativeTo: baseURL) else {
            return value
        }
        return url.absoluteString
    }

    private func shorten(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}

enum DateParsing {
    private static let lock = NSLock()
    private static let formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm:ss ZZZZ",
            "dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let iso = ISO8601DateFormatter()

    static func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            iso.formatOptions = [.withInternetDateTime]
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        for formatter in formatters {
            if let date = formatter.date(from: value) { return date }
        }
        if let number = Double(value), number > 1_000_000_000 {
            return Date(timeIntervalSince1970: number)
        }
        return nil
    }
}
