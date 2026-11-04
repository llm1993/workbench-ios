import Foundation
import SwiftSoup

final class FulltextExtractor {
    static let shared = FulltextExtractor()

    private let junkPatterns = [
        "comment", "share", "social", "related", "recommend", "sidebar", "footer",
        "header", "nav", "advert", "banner", "newsletter", "subscribe", "popup",
        "modal", "qrcode", "author-bio", "breadcrumb", "toolbar", "pagination", "pager"
    ]

    func extract(url: String, title: String) async throws -> String {
        guard let parsed = URL(string: url), let scheme = parsed.scheme, scheme == "http" || scheme == "https" else {
            throw WeiduError.fulltextUnavailable
        }
        let (html, finalURL) = try await FeedService.shared.fetchHTML(url)
        if let result = try? Self.articleHTML(html, base: finalURL.absoluteString, title: title) { return result }
        var challenged = Self.looksChallenged(html)
        // Same fallback as PWA: retry a received but unrecognizable mobile page
        // with desktop headers. Network failures do not cause a second timeout.
        let desktop = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
        if let (second, final) = try? await FeedService.shared.fetchHTML(url, userAgent: desktop) {
            if let result = try? Self.articleHTML(second, base: final.absoluteString, title: title) { return result }
            challenged = challenged || Self.looksChallenged(second)
        }
        throw challenged ? WeiduError.fulltextChallenged : WeiduError.fulltextUnavailable
    }

    static func looksChallenged(_ html: String) -> Bool {
        guard html.count < 30_000 else { return false }
        let lower = html.lowercased()
        return ["name=\"sol\"", "cf-chl", "challenge-platform", "acw_sc__v2", "captcha", "安全验证", "人机验证", "访问验证", "滑块验证"].contains { lower.contains($0) }
    }

    static func articleHTML(_ html: String, base: String, title: String) throws -> String {
        guard let doc = try? SwiftSoup.parse(html, base) else {
            throw WeiduError.fulltextUnavailable
        }

        for element in (try? doc.select("script,style,noscript,object,embed,form,button,input,textarea,select,nav,footer,header,aside,svg,canvas").array()) ?? [] {
            try? element.remove()
        }

        for element in (try? doc.getAllElements().array()) ?? [] {
            let tag = element.tagName().lowercased()
            if tag == "article" || tag == "main" || tag == "body" || tag == "html" { continue }
            let marker = (((try? element.className()) ?? "") + " " + ((try? element.id()) ?? "")).lowercased()
            guard !marker.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard shared.junkPatterns.contains(where: { marker.contains($0) }) else { continue }
            let length = ((try? element.text()) ?? "").count
            if length < 800 {
                try? element.remove()
            }
        }

        shared.normalizeImages(in: doc, base: base)
        shared.absolutizeLinks(in: doc, base: base)

        let selectors = "article, main, [role=main], #js_content, .rich_media_content, .post-content, .entry-content, .article-content, .post-body, .article-body, .content, #content, .post, .article"
        var best: Element?
        var bestScore = 0
        for candidate in (try? doc.select(selectors).array()) ?? [] {
            let textLength = ((try? candidate.text()) ?? "").count
            let paragraphs = (try? candidate.select("p").count) ?? 0
            let score = textLength + paragraphs * 120
            if score > bestScore {
                best = candidate
                bestScore = score
            }
        }

        guard let chosen = best ?? doc.body() else { throw WeiduError.fulltextUnavailable }
        if !title.isEmpty, let heading = try? chosen.select("h1").first(),
           let headingText = try? heading.text(),
           headingText.trimmingCharacters(in: .whitespacesAndNewlines) == title.trimmingCharacters(in: .whitespacesAndNewlines) {
            try? heading.remove()
        }
        for element in (try? chosen.select(".end, .article-end, .post-end").array()) ?? [] {
            try? element.remove()
        }

        let text = (try? chosen.text()) ?? ""
        guard text.count >= 200 else { throw WeiduError.fulltextUnavailable }
        let result = (try? chosen.html()) ?? ""
        guard !result.isEmpty else { throw WeiduError.fulltextUnavailable }
        return ReaderHTML.sanitize(result, base: base, proxyImages: false)
    }

    private func normalizeImages(in doc: Document, base: String) {
        for img in (try? doc.select("img").array()) ?? [] {
            var source = ""
            for key in ["data-src", "data-original", "data-lazy-src", "data-actualsrc", "src"] {
                let value = ((try? img.attr(key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty || value.hasPrefix("data:image") { continue }
                source = value
                break
            }
            guard !source.isEmpty else {
                try? img.remove()
                continue
            }
            if let absolute = URL(string: source, relativeTo: URL(string: base))?.absoluteString {
                try? img.attr("src", absolute)
            }
            for key in ["srcset", "data-src", "data-original", "data-lazy-src", "data-actualsrc", "style", "width", "height"] {
                try? img.removeAttr(key)
            }
        }
    }

    private func absolutizeLinks(in doc: Document, base: String) {
        for link in (try? doc.select("a[href]").array()) ?? [] {
            guard let href = try? link.attr("href"), !href.isEmpty, !href.hasPrefix("#") else { continue }
            if let absolute = URL(string: href, relativeTo: URL(string: base))?.absoluteString {
                try? link.attr("href", absolute)
            }
        }
    }
}
