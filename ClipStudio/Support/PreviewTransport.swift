#if DEBUG
import Foundation
import SwiftUI
import UIKit

// Simulator screenshots exercise the real views without logging in or changing server data.
final class PreviewTransport: URLProtocol {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--design-preview") }
    static var module: WorkspaceApp? {
        let args = ProcessInfo.processInfo.arguments
        guard enabled, let index = args.firstIndex(of: "--preview-module"), index + 1 < args.count else { return nil }
        return WorkspaceApp(rawValue: args[index + 1])
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PreviewTransport.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let json = Self.documents[url.path]
        let fixture = AssetsPreviewFixtures.response(request) ?? Self.clipboardResponse(request)
        let status = fixture?.0 ?? (json == nil ? 404 : 200)
        let data = fixture?.1 ?? Data((json ?? #"{"detail":"No preview fixture"}"#).utf8)
        let contentType = url.path == "/api/export" ? "application/x-ndjson" : "application/json"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }

    static var clipboardAccount: Account {
        Account(base: URL(string: "https://example.invalid")!, token: "preview", username: "预览",
                expires: "2099-01-01T00:00:00Z", keyInfo: KeyInfo(configured: true, key_id: "0123456789abcdef"),
                key: Data(repeating: 1, count: 32))
    }
    private static let clipboardLock = NSLock()
    private static var clipboardRecords: [RemoteClip] = []

    @MainActor static func resetClipboard() -> [ClipRow] {
        let account = clipboardAccount
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360), format: format).image { context in
            UIColor(Theme.surface).setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            let titleAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: UIColor(Theme.text)]
            let detailAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor(Theme.text2)]
            ("剪贴板交互草图" as NSString).draw(at: CGPoint(x: 36, y: 45), withAttributes: titleAttributes)
            ("示例图片 · 接收、预览、复制" as NSString).draw(at: CGPoint(x: 36, y: 100), withAttributes: detailAttributes)
            for (index, label) in ["电脑", "iPhone", "文件中转"].enumerated() {
                let rect = CGRect(x: CGFloat(36 + index * 200), y: 180, width: 172, height: 96)
                UIColor(Theme.accentSoft).setFill(); UIBezierPath(roundedRect: rect, cornerRadius: 14).fill()
                (label as NSString).draw(at: CGPoint(x: rect.minX + 24, y: rect.minY + 32), withAttributes: detailAttributes)
            }
        }
        let bytes = image.pngData() ?? Data()
        let preview = ClipPreview(w: 640, h: 360, b: bytes.count, th: bytes.base64EncodedString())
        let records: [RemoteClip] = (1...40).reversed().compactMap { id in
            let kind = id == 39 ? "image" : "text"
            let text = id == 40 ? "周报整理要点\n本周完成剪贴板交互梳理。\n下周验证搜索、复制与多选管理。" : id == 38 ? "https://developer.apple.com/swift/" : "示例记录 \(id)\n在电脑和手机之间继续工作。"
            do {
                let upload = try ClipCrypto.encrypt(kind == "image" ? bytes : Data(text.utf8), kind: kind,
                                                    preview: kind == "image" ? preview : ClipCrypto.textPreview(text), account: account)
                return RemoteClip(id: id, ts: Date().timeIntervalSince1970 - Double((41 - id) * 120), kind: kind,
                                  source: id % 3 == 0 ? "iphone" : "windows", device: id % 3 == 0 ? "iPhone" : "工作电脑",
                                  key_id: upload.key_id, cid: upload.cid, preview: upload.preview, body: upload.body)
            } catch { return nil }
        }
        clipboardLock.withLock { clipboardRecords = records }
        return records.prefix(30).map { ClipRow(remote: $0, preview: try? ClipCrypto.preview($0, key: account.key)) }
    }

    static func requestBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let length = stream.read(&buffer, maxLength: buffer.count)
            if length <= 0 { return data }
            data.append(contentsOf: buffer.prefix(length))
        }
    }

    private static func clipboardResponse(_ request: URLRequest) -> (Int, Data)? {
        guard let url = request.url else { return nil }
        let path = url.path, method = request.httpMethod ?? "GET"
        func json(_ value: Any, status: Int = 200) -> (Int, Data) {
            (status, (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        }
        if path == "/api/clip/key", method == "GET" {
            return json(["configured": true, "key_id": "0123456789abcdef"])
        }
        if path == "/api/relay/usage", method == "GET" {
            return json(["used": 0, "quota": 1073741824, "ttl_days": 7, "accepting": true, "max_file_iphone": 104857600])
        }
        if path == "/api/relay/files", method == "GET" { return json(["files": [], "uploading": [], "has_more": false]) }
        let itemsPath = "/api/clip/items"
        guard path == itemsPath || path.hasPrefix(itemsPath + "/") else { return nil }
        return clipboardLock.withLock {
            if path == "/api/clip/items", method == "GET" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let before = query.first(where: { $0.name == "before_id" })?.value.flatMap(Int.init)
                let candidates = clipboardRecords.filter { before == nil || $0.id < before! }
                let page = Array(candidates.prefix(30)).map { item -> RemoteClip in
                    var item = item; item.body = nil; return item
                }
                let items = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(page))) ?? []
                return json(["items": items, "has_more": candidates.count > 30, "latest_id": clipboardRecords.first?.id ?? 0])
            }
            if path == "/api/clip/items", method == "POST" {
                guard let payload = try? JSONDecoder().decode(RemotePreviewUpload.self, from: requestBody(request)) else {
                    return json(["detail": "Invalid fixture upload"], status: 400)
                }
                let id = (clipboardRecords.first?.id ?? 0) + 1
                let item = RemoteClip(id: id, ts: Date().timeIntervalSince1970, kind: payload.kind, source: "iphone", device: "iPhone",
                                      key_id: payload.key_id, cid: payload.cid, preview: payload.preview, body: payload.body)
                clipboardRecords.insert(item, at: 0)
                return json(["id": id])
            }
            guard let id = Int(path.split(separator: "/").last ?? ""), let index = clipboardRecords.firstIndex(where: { $0.id == id }) else {
                return json(["detail": "Missing fixture"], status: 404)
            }
            if method == "DELETE" { clipboardRecords.remove(at: index); return json(["ok": true]) }
            if method == "GET" { return (200, (try? JSONEncoder().encode(clipboardRecords[index])) ?? Data()) }
            return json(["detail": "Unsupported fixture action"], status: 405)
        }
    }
    private struct RemotePreviewUpload: Decodable {
        let kind: String
        let key_id: String
        let cid: String
        let preview: String
        let body: String
    }

    static let profileJSON = #"{"username":"预览","is_admin":true,"apps":[{"key":"youshu","name":"有数","desc":"资产与净值看板","hidden":false},{"key":"weidu","name":"未读","desc":"订阅、阅读与多设备同步","hidden":false},{"key":"clip","name":"剪贴板","desc":"手机电脑互传文字与图片","hidden":false},{"key":"stock","name":"股讯","desc":"财经新闻与判断追踪","hidden":false},{"key":"mortgage","name":"房贷","desc":"月供与提前还款方案","hidden":false}]}"#
    private static let documents: [String: String] = [
        "/api/auth/me": profileJSON,
        "/api/mortgage/plans": #"{"items":[]}"#,
        "/api/stock/overview": #"{"report":{"horizons":{"r1":{"rate":0.634,"n":142,"hit":90,"miss":52,"all_up":0.521,"edge":0.018,"flat":8,"ci":[0.55,0.71]}},"raw":280,"total":150,"types":[],"weeks":[],"car":{}},"pipeline":{"enabled":true,"last_eval":"今天 10:30"},"type_labels":{"earnings":"业绩","industry":"行业动态"}}"#,
        "/api/stock/predictions": #"{"predictors":[{"name":"rule","label":"规则判断","rate":0.634,"done":142,"pending":8,"brier":0.214,"ci":[0.55,0.71],"live":150,"backtest":0,"buckets":[]}]}"#,
        "/api/stock/companies": #"{"total":1,"fav_count":3,"groups":[{"code":"600519","name":"贵州茅台","fav":true,"count":1,"tally":{"hit":1,"miss":0,"pending":0},"items":[{"id":1,"title":"关注业绩披露与行业景气变化","decided_at":"今天 09:30","method":"rule","strength":2,"direction":1,"type_label":"业绩","returns":{"r1":0.023}}]}]}"#
    ]
}
#endif
