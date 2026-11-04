import Foundation
import WebKit

final class ImageProxy: NSObject, WKURLSchemeHandler {
    static let shared = ImageProxy()
    static let scheme = "weidu-img"

    private let lock = NSLock()
    private var stoppedTasks: Set<ObjectIdentifier> = []
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func url(for imageURL: String, referer: String) -> String? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "img"
        components.queryItems = [
            URLQueryItem(name: "u", value: imageURL),
            URLQueryItem(name: "r", value: referer)
        ]
        return components.url?.absoluteString
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "u" })?.value,
              let targetURL = URL(string: target),
              let scheme = targetURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            finish(urlSchemeTask, error: URLError(.badURL))
            return
        }
        let referer = components.queryItems?.first(where: { $0.name == "r" })?.value ?? ""
        let id = ObjectIdentifier(urlSchemeTask)
        let task = Task { [weak self] in
            do {
                let image = try await ImageCache.shared.image(url: target, referer: referer)
                self?.deliver(urlSchemeTask, data: image.data, mime: image.mime)
            } catch {
                self?.finish(urlSchemeTask, error: error)
            }
        }
        lock.lock()
        tasks[id] = task
        lock.unlock()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        let id = ObjectIdentifier(urlSchemeTask)
        stoppedTasks.insert(id)
        tasks.removeValue(forKey: id)?.cancel()
        lock.unlock()
    }

    private func deliver(_ task: WKURLSchemeTask, data: Data, mime: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.consumeStopped(task) { return }
            guard let url = task.request.url else { return }
            let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    private func finish(_ task: WKURLSchemeTask, error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.consumeStopped(task) { return }
            task.didFailWithError(error)
        }
    }

    private func consumeStopped(_ task: WKURLSchemeTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(task)
        tasks.removeValue(forKey: id)
        if stoppedTasks.contains(id) {
            stoppedTasks.remove(id)
            return true
        }
        return false
    }

}
