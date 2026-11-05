import Foundation
import CryptoKit
import Security

struct LANPeer: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let fingerprint: String
    let scope: String
    var base: URL? {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.port = port
        return parts.url
    }
}

struct LANIdentity: Codable {
    let id: String
    let seed: Data
    var signingKey: Curve25519.Signing.PrivateKey { get throws { try .init(rawRepresentation: seed) } }
    static func load(scope: String) throws -> Self {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.example.workbench.lan.identity", kSecAttrAccount as String: scope]
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            let identity = try JSONDecoder().decode(Self.self, from: data)
            guard LANProtocol.isHex(identity.id, count: 32), identity.seed.count == 32 else { throw ClipError("局域网设备身份无效") }
            return identity
        }
        guard status == errSecItemNotFound else { throw ClipError("无法读取局域网设备身份，请解锁手机") }
        let identity = Self(id: try ClipCrypto.random(16).hexString, seed: Curve25519.Signing.PrivateKey().rawRepresentation)
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(identity),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        guard SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil) == errSecSuccess else {
            throw ClipError("无法安全保存局域网设备身份")
        }
        return identity
    }
}

enum LANProtocol {
    static let service = "_workbench._tcp."
    static let maxFile = 200 * 1024 * 1024
    static let maxJSON = 128 * 1024
    static let maxChunk = RelayCrypto.chunk + 28

    static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func canonicalServer(_ base: URL) throws -> String {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw ClipError("工作台根地址无效") }
        parts.scheme = "https"; parts.host = host.lowercased(); parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let value = parts.string else { throw ClipError("工作台根地址无效") }
        return value
    }
    static func scope(base: URL, username: String, keyID: String) throws -> String {
        guard isHex(keyID, count: 16), !username.contains("\n") else { throw ClipError("请先解锁剪贴板") }
        let text = "workbench-lan-scope-v1\n\(try canonicalServer(base))\n\(username)\n\(keyID)"
        return Data(SHA256.hash(data: Data(text.utf8))).hexString
    }
    static func authKey(_ dek: Data) throws -> SymmetricKey {
        guard dek.count == 32 else { throw ClipError("请先解锁剪贴板") }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: dek),
            salt: Data("workbench:lan:v1".utf8), info: Data("authentication".utf8), outputByteCount: 32)
    }
    static func discoveryText(scope: String, keyID: String, id: String, fingerprint: String, port: Int, name: String) -> String {
        "workbench-lan-discovery-v1\n\(scope)\n\(keyID)\n\(id)\n\(fingerprint)\n\(port)\n\(name)"
    }
    static func peer(txt: [String: Data], host: String, port: Int, scope: String, keyID: String, key: SymmetricKey) throws -> LANPeer {
        func text(_ name: String) -> String { txt[name].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let id = text("id"), name = text("name"), fingerprint = text("fp")
        guard text("v") == "1", text("scope") == scope, text("key") == keyID,
              isHex(id, count: 32), isHex(fingerprint, count: 64), (1...65535).contains(port),
              !name.isEmpty, name.utf8.count <= 64, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              host.lowercased().hasSuffix(".local.") || host.lowercased().hasSuffix(".local"),
              let mac = Data(base64Encoded: text("mac")), mac.count == 32 else { throw ClipError("附近设备身份未通过验证") }
        let canonical = discoveryText(scope: scope, keyID: keyID, id: id, fingerprint: fingerprint, port: port, name: name)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(canonical.utf8), using: key) else {
            throw ClipError("附近设备不属于当前加密账号")
        }
        return LANPeer(id: id, name: name, host: host.hasSuffix(".") ? String(host.dropLast()) : host,
            port: port, fingerprint: fingerprint, scope: scope)
    }
    static func requestText(hostID: String, clientID: String, time: Int64, nonce: String, method: String, path: String, body: Data) throws -> String {
        guard isHex(hostID, count: 32), isHex(clientID, count: 32), isHex(nonce, count: 32),
              ["GET", "POST", "PUT"].contains(method), path.hasPrefix("/lan/v1/"),
              path.utf8.count <= 160, path.utf8.allSatisfy({ (45...57).contains($0) || (97...122).contains($0) }),
              path.range(of: #"^/lan/v1/(hello|pair|inbox|transfers(?:/[0-9a-f]{16}(?:/(?:accept|decline|complete|received|chunks/(?:0|[1-9][0-9]{0,3})))?)?)$"#, options: .regularExpression) != nil else {
            throw ClipError("局域网请求路径无效")
        }
        return "workbench-lan-request-v1\n\(hostID)\n\(clientID)\n\(time)\n\(nonce)\n\(method)\n\(path)\n\(Data(SHA256.hash(data: body)).hexString)"
    }
    static func headers(peer: LANPeer, identity: LANIdentity, auth: SymmetricKey, method: String, path: String,
                        body: Data, time: Int64 = Int64(Date().timeIntervalSince1970), nonce: String? = nil) throws -> [String: String] {
        let nonce = try nonce ?? ClipCrypto.random(16).hexString
        let text = try requestText(hostID: peer.id, clientID: identity.id, time: time, nonce: nonce, method: method, path: path, body: body)
        let signingKey = try identity.signingKey
        return ["X-WB-Device": identity.id, "X-WB-Key": signingKey.publicKey.rawRepresentation.base64EncodedString(),
            "X-WB-Time": String(time), "X-WB-Nonce": nonce,
            "X-WB-Account": Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: auth)).base64EncodedString(),
            "X-WB-Signature": try signingKey.signature(for: Data(text.utf8)).base64EncodedString()]
    }
    static func metadata(_ manifest: JSONValue, key: Data, keyID: String, limit: Int = maxFile) throws -> JSONValue {
        guard isHex(manifest["fid"].text, count: 16), manifest["key_id"].text == keyID,
              manifest["meta"].text.utf8.count <= 8_000, manifest["thumb"].text.utf8.count <= 100_000 else { throw ClipError("局域网文件信息无效") }
        let meta = try RelayCrypto.openMeta(manifest, key: key)
        guard let sizeNumber = meta["size"].numeric, sizeNumber.isFinite, sizeNumber >= 0, sizeNumber <= Double(limit), sizeNumber.rounded(.towardZero) == sizeNumber else {
            throw ClipError("文件超出局域网接收上限（200 MiB）")
        }
        let size = Int(sizeNumber), count = max(1, (size + RelayCrypto.chunk - 1) / RelayCrypto.chunk)
        guard meta["chunk"].numeric == Double(RelayCrypto.chunk), manifest["chunks"].numeric == Double(count),
              manifest["cipher_size"].numeric == Double(size + count * 28), isHex(meta["sha256"].text, count: 64),
              !meta["name"].text.isEmpty, meta["name"].text.utf8.count <= 1024 else { throw ClipError("文件分块或校验信息无效") }
        return meta
    }
    static func negotiatedLimit(_ value: JSONValue) throws -> Int {
        guard let size = value.numeric, size >= 1, size <= 1_099_511_627_776, size.rounded(.towardZero) == size else {
            throw ClipError("电脑返回了无效的接收上限")
        }
        return min(maxFile, Int(size))
    }
    static func missing(_ value: JSONValue, count: Int) throws -> [Int] {
        guard case .array(let items) = value else { throw ClipError("接收端未返回续传信息") }
        var seen = Set<Int>()
        for item in items {
            guard let number = item.numeric, number >= 0, number < Double(count), number.rounded(.towardZero) == number,
                  seen.insert(Int(number)).inserted else { throw ClipError("接收端续传块号无效") }
        }
        return seen.sorted()
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
