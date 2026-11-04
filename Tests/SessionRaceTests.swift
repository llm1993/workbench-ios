import XCTest
import UIKit
@testable import ClipStudio

private actor ResponseGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true; startedWaiters.forEach { $0.resume() }; startedWaiters = []
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startedWaiters.append($0) } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class DelayedProtocol: URLProtocol {
    static var handle: ((URLRequest) async throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        responseTask = Task {
            do {
                guard let handle = Self.handle else { throw URLError(.badServerResponse) }
                let (status, data) = try await handle(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}

final class SessionRaceTests: XCTestCase {
    private func account(_ username: String, token: String = "old", expires: String = "2099-01-01T00:00:00Z") -> Account {
        Account(base: URL(string: "https://fixture.invalid")!, token: token, username: username, expires: expires,
                keyInfo: KeyInfo(configured: true, key_id: "0123456789abcdef"), key: Data(repeating: 7, count: 32))
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DelayedProtocol.self]
        return URLSession(configuration: config)
    }
    @MainActor func testOldUnlockCannotRestoreAccountAfterLocalLogoutAndSwitch() async throws {
        try Keychain.clear(); let transport = session(), gate = ResponseGate()
        defer { transport.invalidateAndCancel(); DelayedProtocol.handle = nil; try? Keychain.clear() }
        let store = ClipStore(transport: transport); store.account = account("old-user")
        DelayedProtocol.handle = { request in
            XCTAssertEqual(request.url?.path, "/api/clip/key")
            await gate.pause(); return (200, Data(#"{"configured":false}"#.utf8))
        }
        let work = Task { await store.unlock("fixture-passphrase") }
        await gate.waitUntilStarted()
        try store.clearLocalSession(); store.account = account("new-user", token: "new")
        try Keychain.save(store.account!)
        await gate.release(); await work.value
        XCTAssertEqual(store.account?.username, "new-user")
        XCTAssertEqual(try Keychain.load()?.username, "new-user")
        XCTAssertEqual(store.account?.key.count, 32)
    }
    @MainActor func testOldLogoutCannotClearNewAccount() async throws {
        try Keychain.clear(); let transport = session(), gate = ResponseGate()
        defer { transport.invalidateAndCancel(); DelayedProtocol.handle = nil; try? Keychain.clear() }
        let store = ClipStore(transport: transport); store.account = account("old-user")
        DelayedProtocol.handle = { _ in await gate.pause(); return (200, Data(#"{"ok":true}"#.utf8)) }
        let work = Task { await store.logout() }
        await gate.waitUntilStarted()
        try store.clearLocalSession(); store.account = account("new-user", token: "new")
        try Keychain.save(store.account!)
        await gate.release(); await work.value
        XCTAssertEqual(store.account?.username, "new-user")
        XCTAssertEqual(try Keychain.load()?.username, "new-user")
    }
    @MainActor func testLateRenewalCannotReplacePasswordChangeToken() async throws {
        try Keychain.clear(); let transport = session(), gate = ResponseGate()
        defer { transport.invalidateAndCancel(); DelayedProtocol.handle = nil; try? Keychain.clear() }
        let store = ClipStore(transport: transport); store.account = account("fixture", expires: "2000-01-01T00:00:00Z")
        DelayedProtocol.handle = { _ in
            await gate.pause()
            return (200, Data(#"{"access_token":"stale-renewal","username":"fixture","expires_at":"2099-01-01T00:00:00Z"}"#.utf8))
        }
        let work = Task { try await store.renewWorkspaceSession() }
        await gate.waitUntilStarted()
        try store.acceptSessionResponse(.object(["access_token": .string("password-change-token"), "username": .string("fixture"), "expires_at": .string("2099-01-01T00:00:00Z")]), expectedToken: "old")
        await gate.release(); try await work.value
        XCTAssertEqual(store.account?.token, "password-change-token")
        XCTAssertEqual(try Keychain.load()?.token, "password-change-token")
    }
    @MainActor func testDelayedClipboardCopyCannotWriteAfterAccountSwitch() async throws {
        try Keychain.clear(); let transport = session(), gate = ResponseGate()
        defer { transport.invalidateAndCancel(); DelayedProtocol.handle = nil; try? Keychain.clear(); UIPasteboard.general.items = [] }
        let store = ClipStore(transport: transport); store.account = account("old-user")
        let row = ClipRow(remote: RemoteClip(id: 1, ts: 1, kind: "text", source: "windows", device: "电脑",
                                            key_id: "0123456789abcdef", cid: "0000000000000001", preview: ""), preview: nil)
        DelayedProtocol.handle = { request in
            XCTAssertEqual(request.url?.path, "/api/clip/key")
            await gate.pause()
            return (200, Data(#"{"configured":true,"key_id":"0123456789abcdef"}"#.utf8))
        }
        UIPasteboard.general.string = "新账号不应收到旧账号正文"
        let work = Task { await store.copy(row) }
        await gate.waitUntilStarted()
        try store.clearLocalSession(); store.account = account("new-user", token: "new")
        await gate.release(); await work.value
        XCTAssertEqual(UIPasteboard.general.string, "新账号不应收到旧账号正文")
        XCTAssertEqual(store.account?.username, "new-user")
        XCTAssertNil(store.error)
    }
}
