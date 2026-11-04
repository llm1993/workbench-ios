import XCTest
import Combine
import UIKit
@testable import ClipStudio

private actor ClipboardDeletionGate {
    private var started = false
    private var released = false
    private var starter: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true; starter?.resume(); starter = nil
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { starter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private final class ClipboardFixtureBackend {
    let lock = NSLock()
    var account: Account
    var records: [RemoteClip]
    var deletes: [Int] = []
    var failingDeletes = Set<Int>()
    var offline = false
    var requests = 0
    var pages: [Int?] = []

    init(account: Account, records: [RemoteClip]) { self.account = account; self.records = records }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            requests += 1
            if offline { throw URLError(.notConnectedToInternet) }
            let path = request.url!.path
            if path == "/api/clip/key" { return (200, try JSONEncoder().encode(account.keyInfo)) }
            if path == "/api/clip/items" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let before = query.first(where: { $0.name == "before_id" })?.value.flatMap(Int.init)
                pages.append(before)
                let candidates = records.sorted { $0.id > $1.id }.filter { before == nil || $0.id < before! }
                struct Page: Encodable { let items: [RemoteClip]; let has_more: Bool; let latest_id: Int }
                return (200, try JSONEncoder().encode(Page(items: Array(candidates.prefix(30)), has_more: candidates.count > 30,
                                                          latest_id: records.map(\.id).max() ?? 0)))
            }
            guard let id = Int(path.split(separator: "/").last ?? "") else { return (404, Data()) }
            if request.httpMethod == "DELETE" {
                deletes.append(id)
                if failingDeletes.contains(id) { return (503, Data()) }
                records.removeAll { $0.id == id }
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            guard let item = records.first(where: { $0.id == id }) else { return (404, Data()) }
            return (200, try JSONEncoder().encode(item))
        }
    }
}

final class ClipboardLibraryTests: XCTestCase {
    private func account(server: String = "https://fixture.invalid", username: String = "fixture", keyID: String = "0123456789abcdef") -> Account {
        Account(base: URL(string: server)!, token: "fixture", username: username, expires: "2099-01-01T00:00:00Z",
                keyInfo: KeyInfo(configured: true, key_id: keyID), key: Data(repeating: 7, count: 32))
    }
    private func row(_ id: Int, text: String = "示例内容", source: String = "windows", kind: String = "text", cid: String? = nil) -> ClipRow {
        ClipRow(remote: RemoteClip(id: id, ts: Double(id), kind: kind, source: source, device: source == "windows" ? "电脑" : "手机",
                                  key_id: "0123456789abcdef", cid: cid ?? String(format: "%016x", id), preview: ""),
                preview: kind == "text" ? ClipCrypto.textPreview(text) : ClipPreview(w: 1, h: 1))
    }
    private func remote(_ id: Int, account: Account, text: String? = nil) throws -> RemoteClip {
        let text = text ?? "示例内容 \(id)"
        let upload = try ClipCrypto.encrypt(Data(text.utf8), kind: "text", preview: ClipCrypto.textPreview(text), account: account)
        return RemoteClip(id: id, ts: Double(id), kind: "text", source: "windows", device: "电脑",
                          key_id: upload.key_id, cid: upload.cid, preview: upload.preview, body: upload.body)
    }
    private func session(_ backend: ClipboardFixtureBackend) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockProtocol.self]
        MockProtocol.handle = backend.respond
        return URLSession(configuration: configuration)
    }
    private func defaults(_ suite: String) -> UserDefaults { UserDefaults(suiteName: suite)! }

    func testCombinedFiltersUsePreviewAndDeviceAndKeepOnlyMatchingFavorites() {
        let first = row(3, text: "周报整理"), second = row(2, text: "周报", source: "iphone"), image = row(1, kind: "image")
        var filter = ClipboardFilter(favoritesOnly: true, source: .computer, kind: .text, query: " 周报 ")
        let favorites: Set<String> = [ClipboardFavorites.reference(first), ClipboardFavorites.reference(second)]
        XCTAssertEqual(filter.apply(to: [first, second, image], favorites: favorites).map(\.id), [3])
        filter = ClipboardFilter(source: .mobile, query: "手机")
        XCTAssertEqual(filter.apply(to: [first, second, image], favorites: []).map(\.id), [2])
        filter = ClipboardFilter(kind: .image)
        XCTAssertEqual(filter.apply(to: [first, second, image], favorites: []).map(\.id), [1])
        filter = ClipboardFilter(query: "正文后半段")
        let long = row(4, text: String(repeating: "甲", count: 201) + "正文后半段")
        XCTAssertTrue(filter.apply(to: [long], favorites: []).isEmpty, "Search promises previews, not full text")
    }

    func testFavoritesPersistReferencesAndAreIsolatedByServerUserKeyAndCID() {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ClipboardFavorites(defaults: preferences), current = account()
        let item = row(3, text: "DO-NOT-PERSIST-PLAINTEXT")
        let reference = ClipboardFavorites.reference(item)
        library.save([reference], for: current)
        XCTAssertEqual(ClipboardFavorites(defaults: preferences).load(for: current), [reference])
        XCTAssertTrue(library.load(for: account(server: "https://other.invalid")).isEmpty)
        XCTAssertTrue(library.load(for: account(username: "other")).isEmpty)
        XCTAssertTrue(library.load(for: account(keyID: "fedcba9876543210")).isEmpty)
        let reusedID = row(3, cid: "fedcba9876543210")
        XCTAssertFalse(library.load(for: current).contains(ClipboardFavorites.reference(reusedID)))
        XCTAssertFalse(String(describing: preferences.persistentDomain(forName: suite)).contains("DO-NOT-PERSIST-PLAINTEXT"))
        library.clear(for: current)
        XCTAssertTrue(library.load(for: current).isEmpty)
    }

    func testRefreshMergePreservesOlderLoadedRowsAndRemovesMissingRowsInCoveredRange() {
        let loaded = [5, 4, 3, 2, 1].map { row($0) }
        let refreshed = [7, 6, 5, 3].map { row($0) }
        XCTAssertEqual(ClipboardFilter.merge(refreshed, with: loaded, hasMore: true).map(\.id), [7, 6, 5, 3, 2, 1])
        XCTAssertEqual(ClipboardFilter.merge(refreshed, with: loaded, hasMore: false).map(\.id), [7, 6, 5, 3])
        XCTAssertTrue(ClipboardFilter.merge([], with: loaded, hasMore: false).isEmpty)
        XCTAssertEqual(ClipboardFilter.selected([ClipboardFavorites.reference(loaded[3]), ClipboardFavorites.reference(loaded[0])], in: loaded).map(\.id), [5, 2])
    }

    @MainActor func testRefreshPreservesLoadedPagesAndPaginationCursor() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account()
        let backend = ClipboardFixtureBackend(account: current, records: try (1...65).map { try remote($0, account: current) })
        let transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite) }
        let store = ClipStore(transport: transport, defaults: preferences); store.account = current
        await store.refresh(); await store.loadMore()
        XCTAssertEqual(store.rows.map(\.id), Array((6...65).reversed()))
        backend.records += try (66...71).map { try remote($0, account: current) }
        backend.records.removeAll { $0.id == 45 }
        await store.refresh()
        XCTAssertTrue(store.rows.contains { $0.id == 6 })
        XCTAssertFalse(store.rows.contains { $0.id == 45 })
        await store.loadMore()
        XCTAssertEqual(backend.pages.last!, 6)
        XCTAssertTrue(store.rows.contains { $0.id == 1 })
        XCTAssertEqual(Set(store.rows.map(\.id)).count, store.rows.count)
        XCTAssertNil(store.syncFailure)
    }

    @MainActor func testRefreshBridgesMoreThanOneNewPageWithoutLosingLoadedOlderRows() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account()
        let backend = ClipboardFixtureBackend(account: current, records: try (1...40).map { try remote($0, account: current) })
        let transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite) }
        let store = ClipStore(transport: transport, defaults: preferences); store.account = current
        await store.refresh(); await store.loadMore()
        backend.records += try (41...110).map { try remote($0, account: current) }
        await store.refresh()
        XCTAssertEqual(store.rows.map(\.id), Array((1...110).reversed()))
        XCTAssertFalse(store.hasMore)
    }

    @MainActor func testUndoWindowNeverSendsDeleteAndRefreshCannotResurrectHiddenRows() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account()
        let item = try remote(3, account: current), gate = ClipboardDeletionGate()
        let backend = ClipboardFixtureBackend(account: current, records: [item]), transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite) }
        let store = ClipStore(transport: transport, defaults: preferences, deletionWait: { await gate.wait() }); store.account = current
        await store.refresh()
        XCTAssertTrue(store.stageDeletion(store.rows))
        await gate.waitUntilStarted()
        XCTAssertTrue(store.visibleRows.isEmpty)
        await store.refresh()
        XCTAssertTrue(store.visibleRows.isEmpty)
        store.cancelPendingDeletion()
        await gate.release()
        XCTAssertEqual(store.visibleRows.map(\.id), [3])
        XCTAssertTrue(backend.deletes.isEmpty)
    }

    @MainActor func testDeleteCommitsAfterWindowAndRestoresPartialFailuresForRetry() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account(), gate = ClipboardDeletionGate()
        let backend = ClipboardFixtureBackend(account: current, records: try [3, 2].map { try remote($0, account: current) })
        backend.failingDeletes = [2]
        let transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite) }
        let store = ClipStore(transport: transport, defaults: preferences, deletionWait: { await gate.wait() }); store.account = current
        await store.refresh()
        let favorite = store.rows[0]; store.toggleFavorite(favorite)
        let finished = expectation(description: "delete batch finished")
        let subscription = store.$pendingDeletion.dropFirst().filter { $0 == nil }.prefix(1).sink { _ in finished.fulfill() }
        defer { subscription.cancel() }
        XCTAssertTrue(store.stageDeletion(store.rows))
        await gate.waitUntilStarted()
        XCTAssertTrue(backend.deletes.isEmpty)
        await gate.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(backend.deletes, [3, 2])
        XCTAssertEqual(store.visibleRows.map(\.id), [2])
        XCTAssertEqual(store.deletionFailure?.rows.map(\.id), [2])
        XCTAssertTrue(store.deletionFailure?.message.contains("已删除 1 条，1 条未删除") == true)
        XCTAssertFalse(store.isFavorite(favorite))
        backend.failingDeletes = []
        let retried = expectation(description: "retry finished")
        let retrySubscription = store.$pendingDeletion.dropFirst().filter { $0 == nil }.prefix(1).sink { _ in retried.fulfill() }
        defer { retrySubscription.cancel() }
        store.retryDeletion()
        await fulfillment(of: [retried], timeout: 5)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertNil(store.deletionFailure)
    }

    @MainActor func testPendingDeleteAndLocalMarksCannotLeakIntoAnotherAccount() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account(), gate = ClipboardDeletionGate()
        let backend = ClipboardFixtureBackend(account: current, records: [try remote(3, account: current)])
        let transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite) }
        let store = ClipStore(transport: transport, defaults: preferences, deletionWait: { await gate.wait() }); store.account = current
        await store.refresh(); store.toggleFavorite(store.rows[0])
        XCTAssertTrue(store.stageDeletion(store.rows))
        await gate.waitUntilStarted()
        store.account = account(username: "another-user")
        await gate.release()
        XCTAssertNil(store.pendingDeletion)
        XCTAssertTrue(store.favoriteReferences.isEmpty)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(backend.deletes.isEmpty)
    }

    @MainActor func testLockCancelsUnsubmittedDeletion() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account(), gate = ClipboardDeletionGate()
        let backend = ClipboardFixtureBackend(account: current, records: [try remote(3, account: current)])
        let transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite) }
        let store = ClipStore(transport: transport, defaults: preferences, deletionWait: { await gate.wait() }); store.account = current
        await store.refresh(); XCTAssertTrue(store.stageDeletion(store.rows)); await gate.waitUntilStarted()
        store.needsUnlock = true
        await gate.release()
        XCTAssertNil(store.pendingDeletion)
        XCTAssertTrue(backend.deletes.isEmpty)
    }

    @MainActor func testCachedCopyWorksOfflineButRejectsAnotherContext() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account()
        let item = try remote(3, account: current, text: "可离线复制的正文")
        let backend = ClipboardFixtureBackend(account: current, records: [item]), transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite); UIPasteboard.general.items = [] }
        let store = ClipStore(transport: transport, defaults: preferences); store.account = current
        let row = ClipRow(remote: item, preview: ClipCrypto.textPreview("可离线复制的正文"))
        let content = try await store.content(row)
        let requests = backend.requests
        backend.offline = true
        store.copyCached(content)
        XCTAssertEqual(UIPasteboard.general.string, "可离线复制的正文")
        XCTAssertEqual(backend.requests, requests)
        store.account = account(username: "new-user")
        UIPasteboard.general.string = "保持不变"
        store.copyCached(content)
        XCTAssertEqual(UIPasteboard.general.string, "保持不变")
        XCTAssertNotNil(store.error)
    }

    @MainActor func testBatchTextCopyKeepsSelectionOrderAndDoesNotWritePartialResults() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account()
        let first = try remote(3, account: current, text: "第一条"), second = try remote(2, account: current, text: "第二条")
        let backend = ClipboardFixtureBackend(account: current, records: [first, second]), transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite); UIPasteboard.general.items = [] }
        let store = ClipStore(transport: transport, defaults: preferences); store.account = current
        let firstRow = ClipRow(remote: first, preview: nil), secondRow = ClipRow(remote: second, preview: nil)
        await store.copyText([firstRow, secondRow])
        XCTAssertEqual(UIPasteboard.general.string, "第一条\n\n第二条")
        backend.records.removeAll { $0.id == 2 }
        UIPasteboard.general.string = "不能被半份结果覆盖"
        await store.copyText([firstRow, secondRow])
        XCTAssertEqual(UIPasteboard.general.string, "不能被半份结果覆盖")
        XCTAssertNotNil(store.error)
    }

    @MainActor func testContentReadFailureCanBeRetriedAndChangedCIDIsRejected() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite), current = account()
        let item = try remote(3, account: current)
        let backend = ClipboardFixtureBackend(account: current, records: [item]), transport = session(backend)
        defer { transport.invalidateAndCancel(); MockProtocol.handle = nil; preferences.removePersistentDomain(forName: suite) }
        let store = ClipStore(transport: transport, defaults: preferences); store.account = current
        let row = ClipRow(remote: item, preview: nil)
        backend.offline = true
        do { _ = try await store.content(row); XCTFail("Offline read should fail") } catch { }
        backend.offline = false
        let loaded = try await store.content(row)
        XCTAssertEqual(String(data: loaded.data, encoding: .utf8), "示例内容 3")
        backend.records = [try remote(3, account: current, text: "同 ID 的另一份记录")]
        do { _ = try await store.content(row); XCTFail("A changed CID must not be copied as the old row") } catch { }
    }

    @MainActor func testMixedSelectionCannotWriteClipboardAndBusyDeleteIsNotReportedAsSuccess() async throws {
        let suite = "clipboard-tests-" + UUID().uuidString, preferences = defaults(suite)
        defer { preferences.removePersistentDomain(forName: suite); UIPasteboard.general.items = [] }
        let store = ClipStore(defaults: preferences); store.account = account()
        UIPasteboard.general.string = "保持不变"
        await store.copyText([row(3), row(2, kind: "image")])
        XCTAssertEqual(UIPasteboard.general.string, "保持不变")
        XCTAssertNotNil(store.error)
        store.rows = [row(3)]; store.busy = true
        XCTAssertFalse(store.stageDeletion(store.rows))
        XCTAssertNil(store.pendingDeletion)
        XCTAssertEqual(store.visibleRows.count, 1)
    }
}
