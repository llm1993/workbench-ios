import XCTest
@testable import ClipStudio

final class CryptoTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "clip-v1", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func info(_ vector: [String: Any]) throws -> KeyInfo {
        try JSONDecoder().decode(KeyInfo.self, from: JSONSerialization.data(withJSONObject: vector["info"]!))
    }
    private func item(_ vector: [String: Any]) throws -> RemoteClip {
        try JSONDecoder().decode(RemoteClip.self, from: JSONSerialization.data(withJSONObject: vector["item"]!))
    }

    func testIndependentPythonKeyAndUnicodeNormalization() throws {
        let v = try vector()
        let raw = try ClipCrypto.unlock(v["decomposed_passphrase"] as! String, info: info(v))
        XCTAssertEqual(raw.base64EncodedString(), v["key"] as? String)
    }
    func testIndependentPythonTextAndPreview() throws {
        let v = try vector(), item = try item(v)
        let key = Data(base64Encoded: v["key"] as! String)!
        XCTAssertEqual(String(data: try ClipCrypto.open(item.body!, key: key, aad: ClipCrypto.aad(item, part: "body")), encoding: .utf8), v["text"] as? String)
        XCTAssertEqual(try ClipCrypto.preview(item, key: key).t, v["text"] as? String)
    }
    func testIndependentImageBytes() throws {
        let v = try vector(), key = Data(base64Encoded: v["key"] as! String)!
        let bytes = try ClipCrypto.open(v["image_cipher"] as! String, key: key, aad: "clipstudio:item:v1:0123456789abcdef:1111111111111111:image:body")
        XCTAssertEqual(bytes, Data(base64Encoded: v["image"] as! String))
    }
    func testWrongPassphraseIsRejected() throws {
        let v = try vector()
        XCTAssertThrowsError(try ClipCrypto.unlock("incorrect", info: info(v)))
    }
    func testTamperedAADAndTruncationAreRejected() throws {
        let v = try vector(), item = try item(v), key = Data(base64Encoded: v["key"] as! String)!
        XCTAssertThrowsError(try ClipCrypto.open(item.body!, key: key, aad: ClipCrypto.aad(item, part: "preview")))
        XCTAssertThrowsError(try ClipCrypto.open("AAAA", key: key, aad: ""))
        var bytes = Data(base64Encoded: item.body!)!; bytes[12] ^= 1
        XCTAssertThrowsError(try ClipCrypto.open(bytes.base64EncodedString(), key: key, aad: ClipCrypto.aad(item, part: "body")))
    }
    func testPreviewUsesCodepointsRatherThanGraphemesOrUTF16() {
        XCTAssertEqual(ClipCrypto.textPreview("👨‍👩‍👧‍👦e\u{301}\n").n, 10)
        XCTAssertEqual(ClipCrypto.textPreview("").l, 0)
        XCTAssertEqual(ClipCrypto.textPreview("a\nb\n").l, 3)
        XCTAssertEqual(ClipCrypto.textPreview(String(repeating: "😀", count: 210)).t?.unicodeScalars.count, 200)
    }
    func testNewKeyAndUploadRoundTrip() throws {
        let (key, info) = try ClipCrypto.create("test-passphrase")
        XCTAssertEqual(try ClipCrypto.unlock("test-passphrase", info: info), key)
        let account = Account(base: URL(string: "https://example.invalid")!, token: "test", username: "test", expires: "", keyInfo: info, key: key)
        let upload = try ClipCrypto.encrypt(Data("hello".utf8), kind: "text", preview: ClipCrypto.textPreview("hello"), account: account)
        XCTAssertEqual(upload.cid.count, 16)
        XCTAssertEqual(upload.source, "iphone")
        let aad = "clipstudio:item:v1:\(upload.key_id):\(upload.cid):text:body"
        XCTAssertEqual(try ClipCrypto.open(upload.body, key: key, aad: aad), Data("hello".utf8))
    }
    func testUnsafeURLsAreRejected() throws {
        for value in ["http://example.com", "https://user:secret@example.com", "https://example.com/path", "https://example.com?token=x", "https://example.com#fragment"] {
            XCTAssertThrowsError(try ClipAPI.serverURL(value))
        }
        XCTAssertThrowsError(try ClipAPI.serverURL(""))
        XCTAssertThrowsError(try ClipAPI.serverURL(" \n "))
        XCTAssertEqual(try ClipAPI.serverURL(ClipAPI.serverAddressExample).host, "workbench.example.com")
        XCTAssertEqual(try ClipAPI.serverURL(" https://example.com/ ").host, "example.com")
    }
    func testUnconfiguredKeyAndInvalidKDFReject() throws {
        XCTAssertThrowsError(try ClipCrypto.unlock("password", info: KeyInfo(configured: false)))
        XCTAssertThrowsError(try ClipCrypto.derive("password", salt: Data(repeating: 0, count: 16), iterations: 0))
    }
}
