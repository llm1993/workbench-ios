import Foundation

struct OPMLFeed {
    var title: String
    var xmlURL: String
    var htmlURL: String
}

enum OPML {
    static func parse(_ data: Data) -> [OPMLFeed] {
        let delegate = OutlineDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.feeds
    }

    static func export(feeds: [Feed]) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(identifier: "GMT")
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<opml version=\"2.0\">")
        lines.append("<head><title>未读订阅</title><dateCreated>\(date.string(from: Date()))</dateCreated></head>")
        lines.append("<body>")
        for feed in feeds {
            let title = escape(feed.title)
            let xmlURL = escape(feed.url)
            let htmlURL = escape(feed.siteURL)
            var outline = "    <outline type=\"rss\" text=\"\(title)\" title=\"\(title)\" xmlUrl=\"\(xmlURL)\""
            if !htmlURL.isEmpty { outline += " htmlUrl=\"\(htmlURL)\"" }
            outline += "/>"
            lines.append(outline)
        }
        lines.append("</body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class OutlineDelegate: NSObject, XMLParserDelegate {
    var feeds: [OPMLFeed] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName.lowercased() == "outline" else { return }
        var normalized: [String: String] = [:]
        for (key, value) in attributeDict {
            normalized[key.lowercased()] = value
        }
        guard let xmlURL = normalized["xmlurl"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !xmlURL.isEmpty else { return }
        let title = (normalized["title"] ?? normalized["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let htmlURL = (normalized["htmlurl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feeds.contains(where: { $0.xmlURL.caseInsensitiveCompare(xmlURL) == .orderedSame }) else { return }
        feeds.append(OPMLFeed(title: title, xmlURL: xmlURL, htmlURL: htmlURL))
    }
}
