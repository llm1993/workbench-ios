import XCTest
@testable import ClipStudio

final class WorkspaceTests: XCTestCase {
    @MainActor
    func testWorkspaceLoginDoesNotRequireClipboardPermissionOrPassphrase() async throws {
        try Keychain.clear()
        let suite = "workspace-login-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? Keychain.clear(); MockProtocol.handle = nil; defaults.removePersistentDomain(forName: suite) }
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
        let store = ClipStore(transport: session, defaults: defaults)
        let result = await store.login(server: "https://example.invalid", username: "reader", password: "fixture")
        XCTAssertTrue(result)
        XCTAssertEqual(store.account?.username, "reader")
        XCTAssertEqual(store.account?.key.count, 0)
        XCTAssertNil(store.error)
        XCTAssertEqual(try Keychain.load()?.token, "fixture")
        XCTAssertEqual(store.workspaceProfile?.apps.map(\.key), ["weidu"])
        MockProtocol.handle = { _ in XCTFail("Opening the home screen after login should reuse the profile"); return (500, Data()) }
        await store.refreshWorkspaceProfile()
    }

    @MainActor
    func testWorkspaceCatalogSurvivesOfflineRestartButNotAuthorizationFailure() async throws {
        try Keychain.clear()
        let suite = "workspace-offline-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            MockProtocol.handle = nil
            defaults.removePersistentDomain(forName: suite)
            try? Keychain.clear()
        }
        let account = Account(base: URL(string: "https://example.invalid")!, token: "fixture", username: "reader",
                              expires: "2099-01-01T00:00:00Z", keyInfo: KeyInfo(configured: false), key: Data())
        try Keychain.save(account)
        MockProtocol.handle = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/me")
            return (200, Data(#"{"username":"reader","is_admin":true,"apps":[{"key":"weidu","name":"未读","desc":"RSS","hidden":false}]}"#.utf8))
        }
        let first = ClipStore(transport: session, defaults: defaults)
        await first.refreshWorkspaceProfile()
        XCTAssertEqual(first.workspaceProfile?.is_admin, true)

        MockProtocol.handle = { _ in throw URLError(.notConnectedToInternet) }
        let restarted = ClipStore(transport: session, defaults: defaults)
        XCTAssertEqual(restarted.workspaceProfile?.apps.map(\.key), ["weidu"])
        XCTAssertEqual(restarted.workspaceProfile?.is_admin, false)
        await restarted.refreshWorkspaceProfile()
        XCTAssertEqual(restarted.workspaceProfile?.apps.map(\.key), ["weidu"])
        XCTAssertFalse(restarted.workspaceNeedsLogin)

        restarted.account = Account(base: URL(string: "https://other.invalid")!, token: "fixture", username: "reader",
                                    expires: account.expires, keyInfo: account.keyInfo, key: Data())
        XCTAssertNil(restarted.workspaceProfile)
        restarted.account = account
        XCTAssertEqual(restarted.workspaceProfile?.apps.map(\.key), ["weidu"])

        MockProtocol.handle = { _ in (401, Data()) }
        await restarted.refreshWorkspaceProfile(force: true)
        XCTAssertTrue(restarted.workspaceNeedsLogin)
        XCTAssertNil(restarted.workspaceProfile)
        XCTAssertEqual(restarted.workspaceScope, WorkspaceScope(account))
        XCTAssertNil(ClipStore(transport: session, defaults: defaults).workspaceProfile)
    }

    func testLocalDraftsPreserveExistingAccountPathsAndSeparateGuestFiles() throws {
        let account = Account(base: URL(string: "https://example.invalid")!, token: "fixture", username: "reader",
                              expires: "", keyInfo: KeyInfo(configured: false), key: Data())
        let scope = WorkspaceScope(account)
        let suffix = "3f3d13aa9ed1ff28789d684258077fbe5ec3c8f08d66fcba9d9dd86600bb79ed"
        for feature in ["salary", "mortgage"] {
            XCTAssertEqual(WorkspaceScope.draftURL(feature, scope: scope)?.lastPathComponent, "\(feature)-\(suffix).json")
            XCTAssertEqual(WorkspaceScope.draftURL(feature, scope: nil)?.lastPathComponent, "\(feature)-device.json")
        }
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
