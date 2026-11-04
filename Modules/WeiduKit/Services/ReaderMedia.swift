import Foundation
import SwiftSoup

struct ArticleImage: Identifiable, Equatable {
    let url: String
    let largeURL: String
    let alt: String
    var id: String { url + "|" + largeURL }
}

struct ImagePresentation: Identifiable {
    let id = UUID()
    let images: [ArticleImage]
    let index: Int
    let referer: String
}

struct VideoPresentation: Identifiable {
    let id = UUID()
    let url: URL
}

enum ReaderMedia {
    static func httpURL(_ raw: String, base: String = "") -> URL? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !raw.hasPrefix("#") else { return nil }
        guard let url = URL(string: raw, relativeTo: URL(string: base))?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    static func actionURL(_ action: String, url: String, large: String = "", alt: String = "") -> String {
        var components = URLComponents()
        components.scheme = "weidu-reader"
        components.host = action
        components.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "large", value: large), URLQueryItem(name: "alt", value: alt)]
        return components.url?.absoluteString ?? ""
    }

    static func image(from action: URL) -> ArticleImage? {
        let items = URLComponents(url: action, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "url" })?.value, let url = httpURL(raw) else { return nil }
        let large = items.first(where: { $0.name == "large" })?.value ?? ""
        return ArticleImage(url: url.absoluteString, largeURL: httpURL(large)?.absoluteString ?? "", alt: items.first(where: { $0.name == "alt" })?.value ?? "图片")
    }

    static func images(in html: String) -> [ArticleImage] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        return ((try? doc.select("a[href]").array()) ?? []).compactMap { element in
            guard let href = try? element.attr("href"), let url = URL(string: href), url.scheme == "weidu-reader", url.host == "image" else { return nil }
            return image(from: url)
        }
    }

    static func isImageLink(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic"].contains(url.pathExtension.lowercased())
    }
}
