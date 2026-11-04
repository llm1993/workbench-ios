import XCTest
import SwiftUI
@testable import WeiduKit

@MainActor private final class ReaderBodyGate {
    private(set) var waiting: [String: CheckedContinuation<Data, Error>] = [:]
    func transport(_ path: String, method: String, body: Data?) async throws -> Data {
        if path == "/api/weidu/entries/1" || path == "/api/weidu/entries/2" || path == "/api/weidu/entries/1/fulltext" {
            return try await withCheckedThrowingContinuation { waiting[path] = $0 }
        }
        // State acknowledgements do not need a network service in these tests.
        return Data("{}".utf8)
    }
    func finish(_ path: String, entry: CloudValue) throws {
        let data = try JSONEncoder().encode(CloudValue.object(["entry": entry]))
        waiting.removeValue(forKey: path)?.resume(returning: data)
    }
    func fail(_ path: String) { waiting.removeValue(forKey: path)?.resume(throwing: URLError(.notConnectedToInternet)) }
}

final class ReaderLoadingTests: XCTestCase {
    private func entry(_ id: Int, source: String? = nil, fulltext: String? = nil) -> CloudValue {
        .object(["id": .number(Double(id)), "feed_id": .number(1), "title": .string("Article \(id)"),
                 "url": .string("https://fixture.invalid/article/\(id)"), "is_read": .bool(false),
                 "published_at": .string("2026-11-03T10:00:00Z"), "fetched_at": .string("2026-11-03T10:00:00Z"),
                 "feed_html": .string(source ?? "<p>已缓存原文 \(id)</p>"),
                 "content_html": .string(fulltext ?? source ?? "<p>已缓存原文 \(id)</p>"), "has_fulltext": .bool(fulltext != nil)])
    }
    @MainActor private func make(_ gate: ReaderBodyGate) throws -> (Store, Database, URL) {
        let connection = WeiduWorkspaceConnection(scope: "reader-loading-" + UUID().uuidString, navigation: WeiduNavigation(),
            transport: { path, method, body in try await gate.transport(path, method: method, body: body) },
            articleTools: { _, _, _ in AnyView(EmptyView()) })
        let database = Database.workspaceCache(connection)
        try database.mergeCloudFeeds([.object(["id": .number(1), "url": .string("https://fixture.invalid/rss"), "title": .string("Fixture")])])
        for id in [1, 2] { _ = try database.mergeCloudEntry(entry(id), pending: nil, preserveState: false) }
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

    @MainActor func testCloudBodyReadShowsLoadingWhileKeepingCachedContent() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        XCTAssertTrue(store.readerLoadingBody)
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 1"))
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        try gate.finish("/api/weidu/entries/1", entry: entry(1, source: "<p>已同步原文</p>"))
        try await waitUntil { !store.readerLoadingBody }
        XCTAssertTrue(store.readerHTML.contains("已同步原文"))
        XCTAssertFalse(store.readerLoadingFulltext)
    }
    @MainActor func testFailedCloudReadStopsLoadingAndKeepsCachedArticle() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        gate.fail("/api/weidu/entries/1")
        try await waitUntil { !store.readerLoadingBody }
        XCTAssertTrue(store.readerHTML.contains("已缓存原文 1"))
        XCTAssertTrue(store.banner?.text.contains("保留已缓存内容") == true)
    }
    @MainActor func testOldBodyResponseCannotClearNewArticlesLoadingState() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader() }
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
    }
    @MainActor func testClosingReaderClearsLoadingAndRejectsLateDisplayUpdates() async throws {
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader() }
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
        let gate = ReaderBodyGate(), (store, database, _) = try make(gate)
        defer { store.closeReader() }
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
        defer { store.closeReader() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        try gate.finish("/api/weidu/entries/1", entry: entry(1))
        try await waitUntil { !store.readerLoadingBody }
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
        defer { store.closeReader() }
        store.open(try XCTUnwrap(database.entry(id: Database.cloudID(entry(1)))))
        try await waitUntil { gate.waiting["/api/weidu/entries/1"] != nil }
        try gate.finish("/api/weidu/entries/1", entry: entry(1))
        try await waitUntil { !store.readerLoadingBody }
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
