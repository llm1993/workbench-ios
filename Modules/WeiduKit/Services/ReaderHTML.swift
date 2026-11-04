import Foundation
import SwiftSoup

enum ReaderHTML {
    private static let blockedTags: Set<String> = [
        "script", "style", "object", "embed", "form", "input", "button",
        "select", "textarea", "noscript", "svg", "canvas",
        "link", "meta", "source", "track", "template"
    ]

    private static let allowedTags: Set<String> = [
        "p", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "blockquote", "pre", "code", "em", "strong", "b", "i",
        "u", "s", "del", "ins", "a", "img", "figure", "figcaption", "table",
        "thead", "tbody", "tfoot", "tr", "td", "th", "span", "div", "sub", "sup",
        "small", "mark", "dl", "dt", "dd", "cite", "q", "abbr", "time"
    ]

    private static let voidTags: Set<String> = ["br", "hr", "img"]

    static func document(entry: Entry, settings: AppSettings, showFulltext: Bool = true) -> String {
        let base = entry.url
        let feed = sanitize(entry.contentHTML.isEmpty ? entry.summary : entry.contentHTML, base: base)
        let fulltext = entry.fulltextHTML.map { sanitize($0, base: base) } ?? ""
        let sanitized = showFulltext && !fulltext.isEmpty ? fulltext : (feed.isEmpty ? fulltext : feed)
        let canSwitch = !feed.isEmpty && !fulltext.isEmpty && feed != fulltext
        let sourceName = showFulltext && !fulltext.isEmpty ? "原文页抓取" : "订阅源"
        let switchLabel = showFulltext ? "看订阅源原文" : "看抓取的正文"
        let sourceBar = canSwitch ? "<div class=\"source-bar\"><span>正文来源：\(sourceName)</span><a href=\"weidu-reader://source\">\(switchLabel)</a></div>" : ""
        var actions: [String] = []
        if canSwitch { actions.append("<a href=\"weidu-reader://source\">\(switchLabel)</a>") }
        if !entry.hasFulltext && !entry.url.isEmpty { actions.append("<a href=\"weidu-reader://extract\">去原文抓正文</a>") }
        let originalURL = URL(string: entry.url).flatMap { url -> URL? in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        if let url = originalURL {
            actions.append("<a href=\"\(Format.escapeHTML(url.absoluteString))\">打开原文</a>")
        }
        let titleText = Format.escapeHTML(entry.displayTitle)
        let titleHTML = originalURL.map {
            "<h1><a href=\"\(Format.escapeHTML($0.absoluteString))\">\(titleText)</a></h1>"
        } ?? "<h1>\(titleText)</h1>"
        let body = sanitized.isEmpty
            ? "<p class=\"empty\">这篇没有抓到正文，点右上角打开原文。</p>"
            : sanitized

        let fontStack: String
        switch settings.readingFont {
        case .serif: fontStack = "'Songti SC','Noto Serif CJK SC','Source Han Serif SC',Georgia,serif"
        case .sans: fontStack = "-apple-system,'PingFang SC','HarmonyOS Sans SC','Noto Sans CJK SC',sans-serif"
        }
        let size = settings.readingSize

        var metaParts: [String] = []
        if !entry.feedTitle.isEmpty { metaParts.append(entry.feedTitle) }
        if !entry.author.isEmpty { metaParts.append(entry.author) }
        metaParts.append(Format.dayTime(entry.date))
        let meta = metaParts.map { Format.escapeHTML($0) }.joined(separator: " · ")

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
        :root{
          color-scheme:light dark;
          --bg:#f5f5f1; --text:#242b26; --text2:#667060; --text3:#697363;
          --line:rgba(0,0,0,.08); --surface:#efefea;
          --accent:\(settings.accent.lightCSS); --selection:\(settings.accent.selectionLightCSS);
        }
        @media (prefers-color-scheme: dark){
          :root{
            --bg:#151816; --text:#e8ece7; --text2:#adb6ab; --text3:#8b968a;
            --line:rgba(255,255,255,.10); --surface:#252b26;
            --accent:\(settings.accent.darkCSS); --selection:\(settings.accent.selectionDarkCSS);
          }
        }
        *{box-sizing:border-box}
        html{-webkit-text-size-adjust:100%;touch-action:pan-y}
        html,body{margin:0;padding:0;background:var(--bg);color:var(--text)}
        body{
          font-family:\(fontStack);
          font-size:\(size)px;
          line-height:1.85;
          padding:84px \(settings.readingMargin)px 110px;
          max-width:720px;
          margin:0 auto;
          overflow-wrap:break-word;
          -webkit-font-smoothing:antialiased;
        }
        article>h1{
          font-family:-apple-system,'PingFang SC',sans-serif;
          font-size:clamp(23px,1.55em,32px); line-height:1.45; font-weight:650; letter-spacing:-.015em;
          margin:0 0 .7em;
        }
        article>h1 a{color:inherit;border-bottom:0}
        .meta{font-size:.72em;color:var(--text2);margin:0 0 2em;padding-bottom:1.4em;border-bottom:1px solid var(--line);line-height:1.6}
        .content p{margin:1.1em 0}
        .content h2{font-size:1.35em;line-height:1.4;margin:1.6em 0 .5em}
        .content h3{font-size:1.15em;line-height:1.4;margin:1.4em 0 .4em}
        .content h4,.content h5,.content h6{font-size:1em;margin:1.2em 0 .3em}
        a{color:var(--accent);text-decoration:none;border-bottom:.5px solid var(--accent)}
        img{max-width:100%;height:auto;border-radius:8px;margin:1.1em auto;display:block}
        figure{margin:1.2em 0}
        figcaption{font-size:.78em;color:var(--text3);text-align:center;margin-top:.4em}
        blockquote{
          margin:1.2em 0;padding:.2em 0 .2em 1em;border-left:3px solid var(--accent);
          color:var(--text2);
        }
        hr{border:0;border-top:.5px solid var(--line);margin:2em 0}
        pre{
          background:var(--surface);padding:12px 14px;border-radius:8px;
          overflow-x:auto;font-size:.82em;line-height:1.55;
        }
        code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--surface);
          padding:.12em .3em;border-radius:4px;font-size:.88em}
        pre code{background:none;padding:0;font-size:1em}
        table{display:block;max-width:100%;overflow-x:auto;border-collapse:collapse;font-size:.9em;margin:1.2em 0}
        th,td{border:.5px solid var(--line);padding:6px 10px;text-align:left;vertical-align:top}
        ul,ol{padding-left:1.3em;margin:.85em 0}
        li{margin:.3em 0}
        .end{text-align:center;color:var(--text3);font-size:.72em;margin-top:3.5em;letter-spacing:.24em}
        .empty{color:var(--text2);text-align:center;margin-top:2em}
        .source-bar,.reader-actions{font-family:-apple-system,'PingFang SC',sans-serif;font-size:12px;line-height:1.6;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
        .source-bar{color:var(--text2);justify-content:space-between;margin:0 0 24px;padding:12px;background:var(--surface);border-radius:10px}
        .source-bar a,.reader-actions a{padding:6px 10px;border:1px solid var(--line);border-radius:16px}
        .reader-actions{margin-top:28px;justify-content:center}
        .reader-image{border:0;display:block}
        .media-link{display:block;padding:16px;border:1px solid var(--line);border-radius:12px;background:var(--surface);margin:20px 0;text-align:center;font-family:-apple-system,sans-serif;font-size:14px}
        .media-link img{margin:0 auto 12px}
        ::selection{background:var(--selection)}
        </style>
        </head>
        <body>
        <article>
          \(titleHTML)
          <div class="meta">\(meta)</div>
          \(sourceBar)
          <div class="content">\(body)</div>
          <div class="end">— 完 —</div>
          <div class="reader-actions">\(actions.joined())</div>
        </article>
        </body>
        </html>
        """
    }

    static func sanitize(_ html: String, base: String, proxyImages: Bool = true) -> String {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let doc = try? SwiftSoup.parseBodyFragment(html, base), let body = doc.body() else { return "" }
        let rendered = body.getChildNodes().map { render($0, base: base, proxyImages: proxyImages) }.joined()
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ node: Node, base: String, proxyImages: Bool) -> String {
        if node is Comment { return "" }
        if let textNode = node as? TextNode {
            return Format.escapeHTML(textNode.text())
        }
        guard let element = node as? Element else { return "" }
        let tag = element.tagName().lowercased()
        if blockedTags.contains(tag) { return "" }

        if tag == "video" || tag == "audio" {
            let raw = (try? element.attr("src")) ?? ""
            let sources = ((try? element.select("source[src]").array()) ?? []).compactMap {
                ReaderMedia.httpURL((try? $0.attr("src")) ?? "", base: base)
            }
            guard let url = ReaderMedia.httpURL(raw, base: base) ?? sources.first else { return "" }
            let posterURL = ReaderMedia.httpURL((try? element.attr("poster")) ?? "", base: base)
            // Keep persistent cached HTML portable; app controls are added only at display time.
            if !proxyImages {
                let poster = posterURL.map { " poster=\"\(Format.escapeHTML($0.absoluteString))\"" } ?? ""
                return "<\(tag) src=\"\(Format.escapeHTML(url.absoluteString))\"\(poster)></\(tag)>"
            }
            let action = ReaderMedia.actionURL("video", url: url.absoluteString)
            var poster = ""
            if let image = posterURL {
                let source = ImageProxy.url(for: image.absoluteString, referer: base) ?? image.absoluteString
                poster = "<img src=\"\(Format.escapeHTML(source))\" alt=\"视频封面\" loading=\"lazy\">"
            }
            return "<a class=\"media-link\" href=\"\(Format.escapeHTML(action))\">\(poster)▶ \(tag == "audio" ? "播放音频" : "播放视频")</a>"
        }
        if tag == "iframe" {
            guard let raw = try? element.attr("src"), let url = ReaderMedia.httpURL(raw, base: base) else { return "" }
            return "<a class=\"media-link\" href=\"\(Format.escapeHTML(url.absoluteString))\">在原站观看视频</a>"
        }

        if tag == "img" {
            return renderImage(element, base: base, proxyImages: proxyImages)
        }

        let children = element.getChildNodes().map { render($0, base: base, proxyImages: proxyImages) }.joined()
        guard allowedTags.contains(tag) else { return children }

        var attributes = ""
        if tag == "a" {
            // Images have their own app link; avoid nesting anchors from feed markup.
            if proxyImages && children.contains("weidu-reader://image") { return children }
            let href = ((try? element.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = absolute(href, base: base),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return "<span>\(children)</span>"
            }
            attributes = " href=\"\(Format.escapeHTML(url.absoluteString))\""
        } else if tag == "td" || tag == "th" {
            for key in ["colspan", "rowspan"] {
                let value = ((try? element.attr(key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = Int(value), number > 1 {
                    attributes += " \(key)=\"\(number)\""
                }
            }
        } else if tag == "ol" {
            let start = ((try? element.attr("start")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(start) { attributes += " start=\"\(number)\"" }
        }

        if voidTags.contains(tag) { return "<\(tag)\(attributes)>" }
        return "<\(tag)\(attributes)>\(children)</\(tag)>"
    }

    private static func renderImage(_ element: Element, base: String, proxyImages: Bool) -> String {
        let width = ((try? element.attr("width")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let height = ((try? element.attr("height")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if width == "1" && height == "1" { return "" }

        var source = ""
        for key in ["src", "data-src", "data-original", "data-lazy-src", "data-actualsrc"] {
            let value = ((try? element.attr(key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix("data:") { continue }
            source = value
            break
        }
        if source.isEmpty {
            let srcset = ((try? element.attr("srcset")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = srcset.split(separator: ",").first {
                source = first.split(separator: " ").first.map(String.init) ?? ""
            }
        }
        guard let url = absolute(source, base: base),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return "" }

        let referer = URL(string: base)?.absoluteString ?? ""
        let proxied = proxyImages ? (ImageProxy.url(for: url.absoluteString, referer: referer) ?? url.absoluteString) : url.absoluteString
        var attributes = " src=\"\(Format.escapeHTML(proxied))\" loading=\"lazy\""
        let alt = ((try? element.attr("alt")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !alt.isEmpty { attributes += " alt=\"\(Format.escapeHTML(alt))\"" }
        let image = "<img\(attributes)>"
        guard proxyImages else { return image }
        var large = ""
        if let parent = element.parent(), parent.tagName() == "a", let href = try? parent.attr("href"),
           let linked = ReaderMedia.httpURL(href, base: base), ReaderMedia.isImageLink(linked) { large = linked.absoluteString }
        let action = ReaderMedia.actionURL("image", url: url.absoluteString, large: large, alt: alt)
        return "<a class=\"reader-image\" href=\"\(Format.escapeHTML(action))\">\(image)</a>"
    }

    private static func absolute(_ raw: String, base: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("data:"), !value.lowercased().hasPrefix("javascript:") else {
            return nil
        }
        if value.hasPrefix("//") { return URL(string: "https:" + value) }
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
            return URL(string: value)
        }
        guard let baseURL = URL(string: base) else { return nil }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }
}
