import XCTest
import SwiftUI
@testable import WeiduKit

@MainActor private final class ReaderBodyGate {
    private(set) var waiting: [String: CheckedContinuation<Data, Error>] = [:]
    private(set) var requests: [(path: String, method: String, body: Data?, online: Bool)] = []
    var online = true
    func transport(_ path: String, method: String, body: Data?) async throws -> Data {
        requests.append((path, method, body, online))
        guard online else { throw URLError(.notConnectedToInternet) }
        if ["/api/weidu/entries/1", "/api/weidu/entries/2", "/api/weidu/entries/3", "/api/weidu/entries/1/fulltext"].contains(path) {
            guard waiting[path] == nil else {
                XCTFail("Unexpected duplicate request: \(path)")
                throw URLError(.badServerResponse)
            }
            return try await withCheckedThrowingContinuation { waiting[path] = $0 }
        }
        if path == "/api/weidu/overview" {
            return Data(#"{"feeds":[{"id":1,"url":"https://fixture.invalid/rss","title":"Fixture"}],"counts":{"unread":1,"starred":1}}"#.utf8)
        }
        // State acknowledgements do not need a network service in these tests.
        return Data("{}".utf8)
    }
    func finish(_ path: String, entry: CloudValue) throws {
        let data = try JSONEncoder().encode(CloudValue.object(["entry": entry]))
        waiting.removeValue(forKey: path)?.resume(returning: data)
    }
    func fail(_ path: String) { waiting.removeValue(forKey: path)?.resume(throwing: URLError(.notConnectedToInternet)) }
    func failOutstandingRequests() { for path in Array(waiting.keys) { fail(path) } }
}

final class ReaderLoadingTests: XCTestCase {
    private func entry(_ id: Int, source: String? = nil, fulltext: String? = nil) -> CloudValue {
        .object(["id": .number(Double(id)), "feed_id": .number(1), "title": .string("Article \(id)"),
                 "url": .string("https://fixture.invalid/article/\(id)"), "summary": .string("列表摘要 \(id)"), "is_read": .bool(false),
                 "published_at": .string("2026-11-03T10:00:00Z"), "fetched_at": .string("2026-11-03T10:00:00Z"),
                 "feed_html": .string(source ?? "<p>已缓存原文 \(id)</p>"),
                 "content_html": .string(fulltext ?? source ?? "<p>已缓存原文 \(id)</p>"), "has_fulltext": .bool(fulltext != nil)])
    }
    @MainActor private func make(_ gate: ReaderBodyGate, cached: Bool = true, autoFulltext: Bool = false) throws -> (Store, Database, URL) {
        let connection = WeiduWorkspaceConnection(scope: "reader-loading-" + UUID().uuidString, navigation: WeiduNavigation(),
            transport: { path, method, body in try await gate.transport(path, method: method, body: body) },
            articleTools: { _, _, _ in AnyView(EmptyView()) })
        let database = Database.workspaceCache(connection)
        try database.mergeCloudFeeds([.object(["id": .number(1), "url": .string("https://fixture.invalid/rss"),
                                               "title": .string("Fixture"), "auto_fulltext": .bool(autoFulltext)])])
        for id in [1, 2] {
            var item = entry(id)
            if !cached { item["content_html"] = .null; item["feed_html"] = .null }
            _ = try database.mergeCloudEntry(item)
        }
        var settings = AppSettings(); settings.markReadOnOpen = false; settings.refreshMinutes = 0; settings.cacheCleanupDays = 0
        try JSONEncoder().encode(settings).write(to: connection.folder.appendingPathComponent("settings.json"))
        let folder = connection.folder
        // The test's Store/Database must be released before unlinking an open SQLite database.
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (Store(database: database, workspace: connection), database, folder)
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { XCTFail("Reader loading state did not settle"); throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testLoadingStageCoversFetchReadAndRenderWithoutInventingProgress() {
        XCTAssertEqual(ReaderLoadingStage.resolve(fetching: true, reading: true, rendering: true), .fetching)
        XCTAssertEqual(ReaderLoadingStage.resolve(fetching: false, reading: true, rendering: true), .reading)
        XCTAssertEqual(ReaderLoadingStage.resolve(fetching: false, reading: false, rendering: true), .rendering)
        XCTAssertNil(ReaderLoadingStage.resolve(fetching: false, reading: false, rendering: false))
        XCTAssertEqual(ReaderLoadingStage.reading.message, "正在加载原文…")
    }
    func testOldWebKitCompletionCannotEndANewerArticleOrDocument() {
        var state = ReaderRenderingState()
        let first = state.begin(contentID: "first")
        let second = state.begin(contentID: "second")
        XCTAssertFalse(state.finish(first))
        XCTAssertEqual(state.contentID, "second"); XCTAssertTrue(state.loading)
        let updated = state.begin(contentID: "second")
        XCTAssertFalse(state.finish(second), "A source/fulltext switch keeps its own generation")
        XCTAssertTrue(state.finish(updated)); XCTAssertFalse(state.loading)
        XCTAssertFalse(state.finish(updated), "Duplicate didFinish must not be accepted")
    }
    func testFailedRenderingCanRetryAndInvalidationRejectsLateCallbacks() {
        var state = ReaderRenderingState()
        let failed = state.begin(contentID: "article")
        XCTAssertTrue(state.finish(failed, failure: "正文显示未完成"))
        XCTAssertEqual(state.failure, "正文显示未完成"); XCTAssertFalse(state.loading)
        let retried = state.begin(contentID: "article")
        XCTAssertNil(state.failure); XCTAssertTrue(state.loading)
        XCTAssertFalse(state.finish(failed))
        state.invalidate()
        XCTAssertFalse(state.finish(retried)); XCTAssertFalse(state.loading)
    }

    @MainActor func testOfflineCachedArticleReplaysReadAndStarOnReconnect() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        let id = Database.cloudID(1)
        gate.online = false
        await store.openCloudArticle("1")
        let entry = try XCTUnwrap(database.entry(id: id))
        XCTAssertFalse(store.readerLoadingBody)
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 1"))
        store.toggleStar(entry)
        store.toggleRead(entry)
        await store.refreshCloud(fetch: false)
        XCTAssertTrue(gate.requests.contains { $0.path == "/api/weidu/entries/1/state" && !$0.online })
        XCTAssertEqual(store.pendingCloudWrites, 1)
        XCTAssertEqual(database.entry(id: id)?.isRead, true)
        XCTAssertEqual(database.entry(id: id)?.isStarred, true)
        let folder = try XCTUnwrap(store.workspace?.folder)
        let queued = try XCTUnwrap(CloudJournal(folder: folder).state(id))
        XCTAssertTrue(queued["read"].flag)
        XCTAssertTrue(queued["starred"].flag)

        gate.online = true
        await store.refreshCloud(fetch: false)
        XCTAssertEqual(store.pendingCloudWrites, 0)
        XCTAssertTrue(CloudJournal(folder: folder).operations.isEmpty)
        XCTAssertFalse(gate.requests.contains { $0.path == "/api/weidu/entries/1" })
        let sent = try XCTUnwrap(gate.requests.first { $0.path == "/api/weidu/entries/1/state" && $0.online })
        XCTAssertEqual(sent.method, "POST")
        let state = try JSONDecoder().decode(CloudValue.self, from: XCTUnwrap(sent.body))
        XCTAssertTrue(state["opened"].flag)
        XCTAssertTrue(state["starred"].flag)
        XCTAssertTrue(state["read"].flag)
    }
    @MainActor func testCachedBodySkipsAutomaticFulltextEvenWhenEnabledForFeed() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate, autoFulltext: true)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(1))))
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 1"))
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(gate.requests.contains { $0.path == "/api/weidu/entries/1" || $0.path == "/api/weidu/entries/1/fulltext" })
    }
    @MainActor func testMissingBodyIsFetchedOnceEvenWhenServerOnlyHasSummary() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate, cached: false)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        let id = Database.cloudID(1)
        store.open(try XCTUnwrap(database.entry(id: id)))
        XCTAssertTrue(store.readerLoadingBody)
        XCTAssertTrue(store.readerHTML.contains("列表摘要 1"))
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        try gate.finish("/api/weidu/entries/1", entry: entry(1, source: ""))
        try await waitUntil { !store.readerLoadingBody }
        XCTAssertTrue(store.readerEntry?.hasCachedCloudBody == true)
        store.closeReader()
        store.open(try XCTUnwrap(database.entry(id: id)))
        XCTAssertFalse(store.readerLoadingBody)
        XCTAssertTrue(store.readerHTML.contains("列表摘要 1"))
    }
    @MainActor func testUncachedCloudLinkUsesItsFirstResponseAsTheBody() async throws {
        let gate = ReaderBodyGate(), (store, _, _) = try make(gate)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        let open = Task { await store.openCloudArticle("3") }
        try await waitUntil { gate.waiting["/api/weidu/entries/3"] != nil }
        try gate.finish("/api/weidu/entries/3", entry: entry(3))
        await open.value
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 3"))
        XCTAssertFalse(store.readerLoadingBody)
    }
    @MainActor func testManualCloudBodyRefreshShowsLoadingWhileKeepingCachedContent() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        XCTAssertFalse(store.readerLoadingBody)
        let refresh = Task { await store.refreshReaderBody() }
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        XCTAssertTrue(store.readerLoadingBody)
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 1"))
        try gate.finish("/api/weidu/entries/1", entry: entry(1, source: "<p>已同步原文</p>"))
        await refresh.value
        XCTAssertTrue(store.readerHTML.contains("已同步原文"))
        XCTAssertFalse(store.readerLoadingFulltext)
        XCTAssertFalse(store.readerLoadingBody)
    }
    @MainActor func testFailedCloudReadStopsLoadingAndKeepsCachedArticle() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        let refresh = Task { await store.refreshReaderBody() }
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        gate.fail("/api/weidu/entries/1")
        await refresh.value
        XCTAssertFalse(store.readerLoadingBody)
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 1"))
        XCTAssertTrue(store.banner?.text.contains("保留已缓存内容") == true)
    }
    @MainActor func testOldBodyResponseCannotClearNewArticlesLoadingState() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate, cached: false)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(2)))))
        try await waitUntil { gate.waiting["/api/weidu/entries/2"] != nil }
        try gate.finish("/api/weidu/entries/1", entry: entry(1, source: "<p>旧请求已完成</p>"))
        try await waitUntil { database.entry(id: Database.cloudID(entry(1)))?.contentHTML.contains("旧请求已完成") == true }
        XCTAssertEqual(store.readerEntry?.id, Database.cloudID(entry(2)))
        XCTAssertTrue(store.readerLoadingBody)
        XCTAssertFalse(store.readerHTML.contains("旧请求已完成"))
        try gate.finish("/api/weidu/entries/2", entry: entry(2))
        try await waitUntil { !store.readerLoadingBody }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(1))))
        XCTAssertFalse(store.readerLoadingBody)
        XCTAssertTrue(store.readerHTML.contains("旧请求已完成"))
    }
    @MainActor func testClosingReaderClearsLoadingAndRejectsLateDisplayUpdates() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate, cached: false)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        store.closeReader()
        XCTAssertFalse(store.readerLoadingBody)
        try gate.finish("/api/weidu/entries/1", entry: entry(1, source: "<p>关闭后的响应</p>"))
        try await waitUntil { database.entry(id: Database.cloudID(entry(1)))?.contentHTML.contains("关闭后的响应") == true }
        XCTAssertNil(store.readerEntry); XCTAssertTrue(store.readerHTML.isEmpty)
        XCTAssertFalse(store.readerLoadingBody)
    }
    @MainActor func testFulltextSupersedesOlderBodyReadWithoutLeavingItsSpinnerActive() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate, cached: false)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        let fetch = Task { await store.extractFulltext() }
        try await waitUntil { gate.waiting["/api/weidu/entries/1/fulltext"] != nil }
        XCTAssertFalse(store.readerLoadingBody)
        XCTAssertTrue(store.readerLoadingFulltext)
        try gate.finish("/api/weidu/entries/1/fulltext", entry: entry(1, fulltext: "<p>优先显示的新正文</p>"))
        await fetch.value
        XCTAssertFalse(store.readerLoadingBody); XCTAssertFalse(store.readerLoadingFulltext)
        try gate.finish("/api/weidu/entries/1", entry: entry(1, source: "<p>不应覆盖的新旧交错响应</p>"))
        XCTAssertTrue(store.readerHTML.contains("优先显示的新正文"))
    }
    @MainActor func testFailedFulltextStopsLoadingAndKeepsTheExistingSource() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        let fetch = Task { await store.extractFulltext() }
        try await waitUntil { gate.waiting["/api/weidu/entries/1/fulltext"] != nil }
        gate.fail("/api/weidu/entries/1/fulltext")
        await fetch.value
        XCTAssertFalse(store.readerLoadingFulltext)
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 1"))
        XCTAssertTrue(store.banner?.text.contains("抓正文失败") == true)
    }
    @MainActor func testCloudFulltextKeepsCurrentContentUntilReplacementArrives() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader(); gate.failOutstandingRequests() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        let fetch = Task { await store.extractFulltext() }
        try await waitUntil { gate.waiting["/api/weidu/entries/1/fulltext"] != nil }
        XCTAssertTrue(store.readerLoadingFulltext)
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 1"))
        try gate.finish("/api/weidu/entries/1/fulltext", entry: entry(1, fulltext: "<p>完成抓取的新正文</p>"))
        await fetch.value
        XCTAssertFalse(store.readerLoadingFulltext)
        XCTAssertTrue(store.readerHTML.contains("完成抓取的新正文"))
    }
}
