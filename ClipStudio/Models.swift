import Foundation

struct ClipError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct KeyInfo: Codable, Equatable {
    let configured: Bool
    var key_id: String?
    var kdf: String?
    var iterations: Int?
    var salt: String?
    var wrapped_key: String?
}

struct LoginResponse: Decodable {
    let access_token: String
    let username: String
    let expires_at: String
}

struct Account: Codable {
    let base: URL
    var token: String
    let username: String
    var expires: String
    var keyInfo: KeyInfo
    var key: Data
}

struct RemoteClip: Codable, Identifiable {
    let id: Int
    let ts: Double
    let kind: String
    let source: String?
    let device: String?
    let key_id: String
    let cid: String
    let preview: String
    var body: String?
}

struct ClipPage: Decodable {
    let items: [RemoteClip]
    let has_more: Bool
    let latest_id: Int
}

struct ClipPreview: Codable {
    var t: String?
    var n: Int?
    var l: Int?
    var w: Int?
    var h: Int?
    var b: Int?
    var th: String?
}

struct ClipRow: Identifiable {
    let remote: RemoteClip
    let preview: ClipPreview?
    var id: Int { remote.id }
    var title: String { preview?.t ?? (remote.kind == "image" ? "图片" : "无法解密的记录") }
    var device: String { remote.device ?? (remote.source == "windows" ? "电脑" : "其他设备") }
}

struct UploadClip: Encodable {
    let kind: String
    let key_id: String
    let cid: String
    let body: String
    let preview: String
    let source = "iphone"
    let device = "iPhone · 剪贴板"
}
