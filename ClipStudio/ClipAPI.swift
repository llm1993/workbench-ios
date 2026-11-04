import Foundation

struct HTTPFailure: LocalizedError {
    let status: Int
    var payload: Data? = nil
    var retryAfter: Double? = nil
    var errorDescription: String? {
        if status == 422, let payload, let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let issues = body["detail"] as? [[String: Any]] {
            let messages = issues.prefix(3).map { issue -> String in
                let field = (issue["loc"] as? [Any])?.compactMap { $0 as? String }.last ?? "参数"
                let labels = ["name": "名称", "url": "地址", "title": "标题", "selector": "选择器", "amount": "金额", "value": "数值", "count": "数量", "sort": "排序", "interval_minutes": "更新间隔", "push_time": "推送时间", "password": "密码", "new_password": "新密码", "username": "用户名", "due_on": "到期日", "occurred_on": "日期", "purchase_date": "购入日期", "purchase_price": "购入价", "quantity": "数量", "note": "备注"]
                let reason: String
                switch issue["type"] as? String {
                case "missing": reason = "必填"
                case "int_parsing", "int_from_float", "int_type": reason = "须为整数"
                case "decimal_parsing", "decimal_type", "float_parsing", "float_type": reason = "须为有效数字"
                case "string_too_long": reason = "超过允许长度"
                case "string_too_short": reason = "内容太短"
                case "greater_than_equal", "greater_than", "less_than_equal", "less_than": reason = "超出允许范围"
                case "date_parsing", "date_from_datetime_parsing", "date_type": reason = "须为 YYYY-MM-DD 日期"
                default: reason = "格式或取值不正确"
                }
                return (labels[field] ?? "参数") + reason
            }
            if !messages.isEmpty { return messages.joined(separator: "；") }
        }
        if status != 401, let payload,
           let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let detail = body["detail"] as? String, !detail.isEmpty, detail.count <= 240 {
            return detail
        }
        switch status {
        case 401: return "登录已失效，或账号密码不正确，请重新登录"
        case 403: return "当前账号没有使用此功能的权限"
        case 404: return "记录已清理，请刷新列表"
        case 409: return "数据已在其他设备变更，或操作与当前状态冲突，请刷新后重试"
        case 410: return "文件或记录已过期，请刷新列表"
        case 413: return "内容太大，请缩小后重试"
        case 429: return "操作过于频繁，请稍后重试"
        default: return "服务器返回 HTTP \(status)，请稍后重试"
        }
    }
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ClipAPI {
    let base: URL
    var token: String = ""
    var transport: URLSession? = nil
    private static let delegate = RefuseRedirects()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    static let serverAddressExample = "https://workbench.example.com"

    static func serverURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw ClipError("请填写 HTTPS 工作台根地址，例如 \(serverAddressExample)")
        }
        return url
    }

    func bytes(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", timeout: TimeInterval = 35) async throws -> Data {
        guard path.hasPrefix("/api/"), let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host == base.host, url.scheme == base.scheme, url.port == base.port else { throw ClipError("服务器地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await (transport ?? Self.session).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClipError("服务器响应无效") }
        guard (200..<300).contains(http.statusCode) else { throw HTTPFailure(status: http.statusCode, payload: data, retryAfter: Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")) }
        return data
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await bytes(path, method: method, body: body)
        do { return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data) }
        catch { throw ClipError("服务器数据格式无效，请检查工作台地址") }
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password,
                                                             "client": "web", "device": "iPhone · 工作台"])
        return try await request("/api/auth/login", method: "POST", body: body)
    }

    func key() async throws -> KeyInfo { try await request("/api/clip/key") }
    func page(before: Int? = nil) async throws -> ClipPage {
        try await request("/api/clip/items?limit=30" + (before.map { "&before_id=\($0)" } ?? ""))
    }
    func item(_ id: Int) async throws -> RemoteClip { try await request("/api/clip/items/\(id)") }
    func logout() async throws { let _: OK = try await request("/api/auth/logout", method: "POST") }
    struct OK: Decodable { let ok: Bool }
}
