import XCTest
@testable import ClipStudio

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testWorkspaceLoginDoesNotRequireClipboardPermissionOrPassphrase() async throws {
        try Keychain.clear()
        defer { try? Keychain.clear(); MockProtocol.handle = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        MockProtocol.handle = { request in
            switch request.url!.path {
            case "/api/auth/login": return (200, Data(#"{"access_token":"fixture","username":"reader","expires_at":"2099-01-01T00:00:00Z"}"#.utf8))
            case "/api/auth/me": return (200, Data(#"{"username":"reader","is_admin":false,"apps":[{"key":"weidu","name":"未读","desc":"RSS","hidden":false}]}"#.utf8))
            default: XCTFail("Login must not request clipboard APIs"); return (403, Data())
            }
        }
        let store = ClipStore(transport: session)
        let result = await store.login(server: "https://example.invalid", username: "reader", password: "fixture")
        XCTAssertTrue(result)
        XCTAssertEqual(store.account?.username, "reader")
        XCTAssertEqual(store.account?.key.count, 0)
        XCTAssertNil(store.error)
        XCTAssertEqual(try Keychain.load()?.token, "fixture")
    }

    func testCatalogPreservesServerOrderAndHiddenModules() throws {
        let data = Data(#"{"username":"reader","is_admin":false,"apps":[{"key":"weidu","name":"未读","desc":"RSS","hidden":true},{"key":"clip","name":"剪贴板","desc":"同步","hidden":false}]}"#.utf8)
        let profile = try JSONDecoder().decode(WorkspaceProfile.self, from: data)
        XCTAssertEqual(profile.apps.map(\.key), ["weidu", "clip"])
        XCTAssertEqual(profile.apps.filter { !$0.hidden }.map(\.key), ["clip"])
        XCTAssertFalse(profile.is_admin)
    }

    func testAppLayoutKeepsUniqueNamesAndVisibilityAfterReordering() throws {
        let data = Data(#"{"apps":[{"key":"youshu","name":"有数","desc":"资产","hidden":false},{"key":"weidu","name":"未读","desc":"RSS","hidden":false},{"key":"clip","name":"剪贴板","desc":"同步","hidden":false},{"key":"stock","name":"股讯","desc":"判断","hidden":false},{"key":"mortgage","name":"房贷","desc":"试算","hidden":false}]}"#.utf8)
        var layout = try JSONDecoder().decode(WorkspaceAppLayout.self, from: data)
        XCTAssertEqual(Set(layout.apps.map(\.id)).count, 5)
        XCTAssertEqual(layout.apps.map(\.name), ["有数", "未读", "剪贴板", "股讯", "房贷"])
        layout.apps.swapAt(0, 1)
        layout.apps[0].isVisible = false
        XCTAssertEqual(layout.apps[0].name, "未读")
        XCTAssertEqual(layout.payload["order"].array.map(\.text), ["weidu", "youshu", "clip", "stock", "mortgage"])
        XCTAssertEqual(layout.payload["hidden"], .strings(["weidu"]))
        XCTAssertFalse(layout.apps[1].hidden)
    }
}
