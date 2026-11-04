import Foundation
import CryptoKit
import CommonCrypto
import Security

enum ClipCrypto {
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw ClipError("系统随机数不可用") }
        return data
    }

    static func derive(_ passphrase: String, salt: Data, iterations: Int) throws -> Data {
        guard (100_000...5_000_000).contains(iterations), (12...48).contains(salt.count) else {
            throw ClipError("不支持的密钥参数")
        }
        let password = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        input.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw ClipError("密钥派生失败") }
        return key
    }

    static func seal(_ data: Data, key: Data, aad: String) throws -> String {
        guard key.count == 32 else { throw ClipError("内容密钥无效") }
        let sealed = try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
        guard let combined = sealed.combined else { throw ClipError("加密失败") }
        return combined.base64EncodedString()
    }

    static func open(_ text: String, key: Data, aad: String) throws -> Data {
        guard key.count == 32, let data = Data(base64Encoded: text), data.count >= 28 else {
            throw ClipError("密文格式无效")
        }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key),
                                    authenticating: Data(aad.utf8))
        } catch { throw ClipError("内容无法解密，请检查加密口令或重新解锁") }
    }

    static func unlock(_ passphrase: String, info: KeyInfo) throws -> Data {
        guard info.configured, info.kdf == "PBKDF2-SHA256", let iterations = info.iterations,
              let saltText = info.salt, let salt = Data(base64Encoded: saltText),
              let wrapped = info.wrapped_key, let id = info.key_id else { throw ClipError("密钥信息无效") }
        let kek = try derive(passphrase, salt: salt, iterations: iterations)
        let key = try open(wrapped, key: kek, aad: "clipstudio:key:v1:\(id)")
        guard key.count == 32 else { throw ClipError("内容密钥无效") }
        return key
    }

    static func create(_ passphrase: String) throws -> (Data, KeyInfo) {
        guard passphrase.unicodeScalars.count >= 8 else { throw ClipError("首次设置的加密口令至少 8 位") }
        let key = try random(32), salt = try random(16)
        let id = try random(8).map { String(format: "%02x", $0) }.joined()
        let kek = try derive(passphrase, salt: salt, iterations: 600_000)
        let wrapped = try seal(key, key: kek, aad: "clipstudio:key:v1:\(id)")
        return (key, KeyInfo(configured: true, key_id: id, kdf: "PBKDF2-SHA256", iterations: 600_000,
                             salt: salt.base64EncodedString(), wrapped_key: wrapped))
    }

    static func rewrap(old: String, new: String, info: KeyInfo) throws -> (Data, KeyInfo) {
        guard new.unicodeScalars.count >= 8 else { throw ClipError("新加密口令至少 8 位") }
        let key = try unlock(old, info: info), salt = try random(16)
        guard let id = info.key_id else { throw ClipError("密钥无效") }
        let kek = try derive(new, salt: salt, iterations: 600_000)
        let wrapped = try seal(key, key: kek, aad: "clipstudio:key:v1:\(id)")
        return (key, KeyInfo(configured: true, key_id: id, kdf: "PBKDF2-SHA256", iterations: 600_000,
                             salt: salt.base64EncodedString(), wrapped_key: wrapped))
    }

    static func suggestPassphrase() throws -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var output = ""
        while output.count < 20 {
            for b in try random(32) where b < 252 {
                if output.count == 20 { break }
                output.append(alphabet[Int(b) % 36])
            }
        }
        let chars = Array(output)
        return stride(from: 0, to: 20, by: 4).map { String(chars[$0..<($0 + 4)]) }.joined(separator: "-")
    }

    static func aad(_ item: RemoteClip, part: String) -> String {
        "clipstudio:item:v1:\(item.key_id):\(item.cid):\(item.kind):\(part)"
    }

    static func preview(_ item: RemoteClip, key: Data) throws -> ClipPreview {
        try JSONDecoder().decode(ClipPreview.self, from: open(item.preview, key: key, aad: aad(item, part: "preview")))
    }

    static func textPreview(_ text: String) -> ClipPreview {
        ClipPreview(t: String(String.UnicodeScalarView(text.unicodeScalars.prefix(200))),
                    n: text.unicodeScalars.count, l: text.isEmpty ? 0 : text.components(separatedBy: "\n").count)
    }

    static func encrypt(_ data: Data, kind: String, preview: ClipPreview, account: Account) throws -> UploadClip {
        guard data.count <= 8 * 1024 * 1024 else { throw ClipError("内容超过 8 MiB，请缩小后再发送") }
        guard let keyID = account.keyInfo.key_id else { throw ClipError("请先解锁") }
        let cid = try random(8).map { String(format: "%02x", $0) }.joined()
        let prefix = "clipstudio:item:v1:\(keyID):\(cid):\(kind):"
        return UploadClip(kind: kind, key_id: keyID, cid: cid,
                          body: try seal(data, key: account.key, aad: prefix + "body"),
                          preview: try seal(JSONEncoder().encode(preview), key: account.key, aad: prefix + "preview"))
    }
}
