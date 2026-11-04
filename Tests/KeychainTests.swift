import XCTest
import Security
@testable import ClipStudio

final class KeychainTests: XCTestCase {
    func testNeutralApplicationAndKeychainIdentity() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.example.workbench")
        XCTAssertEqual(Keychain.query[kSecAttrService as String] as? String, "com.example.workbench")
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, ["workbench"])
    }
    func testSaveRestoreReplaceAndLogout() throws {
        // Isolated simulator test host; no production account or network.
        try Keychain.clear()
        defer { try? Keychain.clear() }
        XCTAssertNil(try Keychain.load())
        var account = Account(base: URL(string: "https://example.invalid")!, token: "fixture-token", username: "fixture",
                              expires: "2099-01-01T00:00:00Z", keyInfo: KeyInfo(configured: true, key_id: "0123456789abcdef"),
                              key: Data(repeating: 7, count: 32))
        try Keychain.save(account)
        let restored = try XCTUnwrap(Keychain.load())
        XCTAssertEqual(restored.token, account.token)
        XCTAssertEqual(restored.key, account.key)
        XCTAssertEqual(restored.keyInfo, account.keyInfo)
        account.token = "renewed-token"
        try Keychain.save(account)
        XCTAssertEqual(try Keychain.load()?.token, "renewed-token")
        try Keychain.clear()
        XCTAssertNil(try Keychain.load())
    }
}
