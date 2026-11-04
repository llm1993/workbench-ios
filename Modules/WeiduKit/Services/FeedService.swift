import Foundation
import SwiftSoup

struct FetchedFeed {
    var title: String
    var siteURL: String
    var entries: [ParsedEntry]
    var etag: String
    var lastModified: String
}

struct FeedFetchOutcome {
    let feedID: String
    let result: Result<FetchedFeed?, WeiduError>
}

final class FeedService {
    static let shared = FeedService()
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 Weidu/0.1"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": FeedService.userAgent,
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.6"
        ]
        session = URLSession(configuration: config)
    }

    func fetchOutcome(_ feed: Feed) async -> FeedFetchOutcome {
        do {
            let value = try await fetch(feed)
            return FeedFetchOutcome(feedID: feed.id, result: .success(value))
        } catch let error as WeiduError {
            return FeedFetchOutcome(feedID: feed.id, result: .failure(error))
        } catch {
            return FeedFetchOutcome(feedID: feed.id, result: .failure(.network(error.localizedDescription)))
        }
    }

    func fetch(_ feed: Feed) async throws -> FetchedFeed? {
        guard let url = URL(string: feed.url) else { throw WeiduError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        if !feed.etag.isEmpty { request.setValue(feed.etag, forHTTPHeaderField: "If-None-Match") }
        if !feed.lastModified.isEmpty { request.setValue(feed.lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let result: (Data, HTTPURLResponse)
        do {
            result = try await send(request)
        } catch let error as WeiduError {
            throw error
        } catch {
            throw WeiduError.network(error.localizedDescription)
        }
        let data = result.0
        let http = result.1

        if http.statusCode == 304 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw WeiduError.http(http.statusCode) }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        let text = HTMLText.decode(data, contentType: contentType)
        guard HTMLText.looksLikeFeed(text) else { throw WeiduError.notAFeed }

        let parsed = try FeedParser(data: HTMLText.prepareXML(text)).parse()
        return FetchedFeed(
            title: parsed.title,
            siteURL: parsed.siteURL,
            entries: parsed.entries,
            etag: http.value(forHTTPHeaderField: "ETag") ?? "",
            lastModified: http.value(forHTTPHeaderField: "Last-Modified") ?? ""
        )
    }

    func discover(_ raw: String) async throws -> [DiscoveredFeed] {
        guard let inputURL = Format.normalizedURL(raw) else { throw WeiduError.invalidURL }

        var firstError: WeiduError?
        let candidates = [inputURL] + fallbackPaths(for: inputURL)
        for candidate in candidates {
            do {
                let (text, finalURL) = try await fetchHTML(candidate.absoluteString)
                if HTMLText.looksLikeFeed(text) {
                    let parsed = try FeedParser(data: HTMLText.prepareXML(text)).parse()
                    let title = parsed.title.isEmpty ? Format.host(finalURL.absoluteString) : parsed.title
                    return [DiscoveredFeed(title: title, url: finalURL.absoluteString)]
                }
                let found = try discoverInHTML(text, base: finalURL)
                if !found.isEmpty { return found }
            } catch let error as WeiduError {
                if firstError == nil { firstError = error }
            } catch {
                if firstError == nil { firstError = .network(error.localizedDescription) }
            }
        }
        throw firstError ?? WeiduError.notAFeed
    }

    private func fallbackPaths(for url: URL) -> [URL] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path
        guard path.isEmpty || path == "/" else { return [] }
        var results: [URL] = []
        for suffix in ["/feed", "/feed/", "/rss", "/rss.xml", "/atom.xml", "/index.xml"] {
            components.path = suffix
            if let candidate = components.url { results.append(candidate) }
        }
        return results
    }

    private func discoverInHTML(_ html: String, base: URL) throws -> [DiscoveredFeed] {
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        var results: [DiscoveredFeed] = []
        let pageTitle = ((try? doc.title()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let links = try doc.select("link[href]").array()
        for link in links {
            let type = ((try? link.attr("type")) ?? "").lowercased()
            let rel = ((try? link.attr("rel")) ?? "").lowercased()
            let isFeedType = type.contains("rss") || type.contains("atom") || type.contains("feed+")
            guard isFeedType || (type.contains("xml") && rel.contains("alternate")) else { continue }
            guard let href = try? link.attr("href"), !href.isEmpty else { continue }
            guard let absolute = URL(string: href, relativeTo: base)?.absoluteString else { continue }
            if results.contains(where: { $0.url == absolute }) { continue }
            let declared = ((try? link.attr("title")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = declared.isEmpty ? (pageTitle.isEmpty ? Format.host(absolute) : pageTitle) : declared
            results.append(DiscoveredFeed(title: title, url: absolute))
        }
        return results
    }

    func fetchHTML(_ raw: String, userAgent: String? = nil) async throws -> (String, URL) {
        guard let url = URL(string: raw) else { throw WeiduError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let result: (Data, HTTPURLResponse)
        do {
            result = try await send(request)
        } catch let error as WeiduError {
            throw error
        } catch {
            throw WeiduError.network(error.localizedDescription)
        }
        let data = result.0
        let http = result.1
        guard (200..<300).contains(http.statusCode) else { throw WeiduError.http(http.statusCode) }
        let text = HTMLText.decode(data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        return (text, http.url ?? url)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WeiduError.network("没有收到有效响应")
        }
        return (data, http)
    }
}

enum HTMLText {
    static func looksLikeFeed(_ text: String) -> Bool {
        let head = String(text.prefix(4000)).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf") || head.contains("<rdf ")
    }

    static func decode(_ data: Data, contentType: String?) -> String {
        let sniffed = sniffCharset(data) ?? charset(in: contentType)
        if let sniffed, let encoding = encoding(named: sniffed), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let gb = encoding(named: "gb18030"), let text = String(data: data, encoding: gb) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func charset(in contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.lowercased().hasPrefix("charset=") {
                return piece.dropFirst("charset=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
        }
        return nil
    }

    private static func sniffCharset(_ data: Data) -> String? {
        let prefix = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        for pattern in ["charset=[\"']?([a-z0-9_\\-]+)", "encoding=[\"']?([a-z0-9_\\-]+)"] {
            guard let range = prefix.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(prefix[range])
            if let eq = matched.firstIndex(of: "=") {
                return matched[matched.index(after: eq)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    static func encoding(named name: String) -> String.Encoding? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(cleaned as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
        switch cleaned {
        case "gb2312", "gbk", "gb18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        default:
            return nil
        }
    }

    static func prepareXML(_ text: String) -> Data {
        var xml = text
        if xml.hasPrefix("\u{FEFF}") { xml.removeFirst() }
        for pattern in ["encoding=\"[^\"]*\"", "encoding='[^']*'"] {
            if let range = xml.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                xml.replaceSubrange(range, with: "encoding=\"utf-8\"")
            }
        }
        var cleaned = ""
        cleaned.unicodeScalars.append(contentsOf: xml.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || scalar.value >= 20
        })
        return Data(cleaned.utf8)
    }
}
