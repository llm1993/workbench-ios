import XCTest
import SwiftUI
import Combine
@testable import WeiduKit

@MainActor private final class PagingServer {
    var paths: [String] = []
    var failNextPage = false
    var prefs: CloudValue = .object(["auto_read_on_scroll": .bool(true)])
    var rows: [CloudValue] = (1...100).map { number in
        .object(["id": .number(Double(number)), "feed_id": .number(1), "title": .string("Article \(number)"),
                 "published_at": number % 3 == 0 ? .null : .string("2026-11-02T10:00:00Z"),
                 "fetched_at": .string("2026-11-03T10:00:00Z"), "is_read": .bool(false), "is_starred": .bool(true)])
    }

    func bytes(_ path: String, method: String, body: Data?) async throws -> Data {
        paths.append(path)
        let value: CloudValue
        if path == "/api/weidu/overview" {
            value = .object(["feeds": .array([.object(["id": .number(1), "url": .string("https://fixture.invalid/rss"), "title": .string("Fixture"), "unread": .number(Double(rows.filter { !$0["is_read"].flag }.count))])]),
                             "counts": .object(["unread": .number(Double(rows.filter { !$0["is_read"].flag }.count)), "starred": .number(Double(rows.count))]), "prefs": prefs])
        } else if path.hasPrefix("/api/weidu/entries?") {
            let query = URLComponents(string: "https://fixture.invalid" + path)!.queryItems!
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            let limit = Int(query.first { $0.name == "limit" }!.value!)!
            if offset > 0, failNextPage { failNextPage = false; throw URLError(.networkConnectionLost) }
            let view = query.first { $0.name == "view" }?.value
            let matching = rows.filter { view == "unread" ? !$0["is_read"].flag : view == "starred" ? $0["is_starred"].flag : true }
            value = .object(["items": .array(Array(matching.dropFirst(offset).prefix(limit))), "has_more": .bool(offset + limit < matching.count)])
        } else if path == "/api/weidu/entries/state" {
            let payload = try JSONDecoder().decode(CloudValue.self, from: XCTUnwrap(body))
            let ids = Set(payload["ids"].array.map(\.int))
            for index in rows.indices where ids.contains(rows[index]["id"].int) { rows[index]["is_read"] = payload["read"] }
            value = .object([:])
        } else { value = .object([:]) }
        return try JSONEncoder().encode(value)
    }
}

final class CloudPagingTests: XCTestCase {
    @MainActor private func make(_ server: PagingServer) throws -> (Store, URL) {
        let connection = WeiduWorkspaceConnection(scope: "paging-" + UUID().uuidString, navigation: WeiduNavigation(),
            transport: { path, method, body in try await server.bytes(path, method: method, body: body) },
            articleTools: { _, _, _ in AnyView(EmptyView()) })
        try FileManager.default.createDirectory(at: connection.folder, withIntermediateDirectories: true)
        var settings = AppSettings(); settings.autoReadOnScroll = true
        try JSONEncoder().encode(settings).write(to: connection.folder.appendingPathComponent("settings.json"))
        return (Store(workspace: connection), connection.folder)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { XCTFail("Reader operation did not settle"); throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor func testNextPageIsIncrementalAfterReadAcknowledgementsAndDoesNotSkipRows() async throws {
        let server = PagingServer(), (store, folder) = try make(server)
        defer { try? FileManager.default.removeItem(at: folder) }
        await store.refreshCloud(fetch: false)
        try await waitUntil { store.entries.count == 40 && !store.isLoadingMore }
        XCTAssertEqual(store.entries.map { Int($0.id)! }, Array(1...40), "Keep server order, including null published dates")
        store.markScrolledEntriesRead(Set(store.entries.prefix(10).map(\.id)))
        try await waitUntil { store.pendingCloudWrites == 0 }
        store.loadMore(); store.loadMore()
        try await waitUntil { store.entries.count == 80 && !store.isLoadingMore }
        XCTAssertEqual(store.entries.map { Int($0.id)! }, Array(1...80))
        store.loadMore()
        try await waitUntil { store.entries.count == 100 && !store.isLoadingMore }
        XCTAssertFalse(store.hasMore)
        let pages = server.paths.filter { $0.hasPrefix("/api/weidu/entries?") }.compactMap { URLComponents(string: "https://fixture.invalid" + $0)?.queryItems }
        XCTAssertEqual(pages.count, 3, "A second call while loading cannot start a duplicate page")
        XCTAssertEqual(pages.map { $0.first { $0.name == "offset" }!.value! }, ["0", "30", "70"])
        XCTAssertTrue(pages.allSatisfy { $0.first { $0.name == "limit" }?.value == "40" })
    }

    @MainActor func testForegroundSyncKeepsAllLoadedRowsAndDoesNotReapplyListGeometry() async throws {
        let server = PagingServer(), (store, folder) = try make(server)
        defer { try? FileManager.default.removeItem(at: folder) }
        await store.refreshCloud(fetch: false)
        try await waitUntil { store.entries.count == 40 && !store.isLoadingMore }
        store.loadMore()
        try await waitUntil { store.entries.count == 80 && !store.isLoadingMore }
        let before = store.entries, pathsBefore = server.paths.count
        var publications = 0
        let observation = store.$entries.dropFirst().sink { _ in publications += 1 }
        server.prefs = .object(["list_view": .string("all"), "density": .string("compact")])
        await store.refreshCloud(fetch: false, preservingList: true)
        XCTAssertEqual(store.entries, before)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(store.settings.listView, .unread)
        XCTAssertEqual(store.settings.density, .normal)
        XCTAssertFalse(server.paths.dropFirst(pathsBefore).contains { $0.hasPrefix("/api/weidu/entries?") })
        let requests = server.paths.count
        await store.refreshIfNeeded()
        XCTAssertEqual(server.paths.count, requests, "An immediate second foreground event does not refetch")
        withExtendedLifetime(observation) {}
    }

    @MainActor func testFailedPrefetchKeepsRowsAndCanRetryWithoutAnAutomaticRequestLoop() async throws {
        let server = PagingServer(), (store, folder) = try make(server)
        defer { try? FileManager.default.removeItem(at: folder) }
        await store.refreshCloud(fetch: false)
        try await waitUntil { store.entries.count == 40 && !store.isLoadingMore }
        let before = store.entries
        server.failNextPage = true
        store.loadMore()
        try await waitUntil { store.listPageError != nil && !store.isLoadingMore }
        XCTAssertEqual(store.entries, before)
        let requestCount = server.paths.count
        store.loadMore()
        XCTAssertEqual(server.paths.count, requestCount)
        store.retryLoadMore()
        try await waitUntil { store.entries.count == 80 && !store.isLoadingMore }
        XCTAssertNil(store.listPageError)
        XCTAssertEqual(Array(store.entries.prefix(40)), before)
    }

    @MainActor func testDoubleTapHidesReadRowsAndReturnsToTopWithoutResettingPagination() async throws {
        let server = PagingServer(), (store, folder) = try make(server)
        defer { try? FileManager.default.removeItem(at: folder) }
        await store.refreshCloud(fetch: false)
        try await waitUntil { store.entries.count == 40 && !store.isLoadingMore }
        store.markScrolledEntriesRead(Set(store.entries.prefix(10).map(\.id)))
        try await waitUntil { store.pendingCloudWrites == 0 }
        let requests = server.paths.count
        var commands: [AppTab] = []
        let observation = store.scrollToTop.sink { commands.append($0) }
        store.handleTabDoubleTap(.articles)
        XCTAssertEqual(commands, [.articles])
        XCTAssertEqual(store.entries.map { Int($0.id)! }, Array(11...40))
        XCTAssertEqual(server.paths.count, requests)
        XCTAssertEqual(store.settings.listView, .unread)
        let db = Database(url: folder.appendingPathComponent("reader.sqlite3"))
        XCTAssertTrue(db.entry(id: String(format: "%020lld", Int64(1)))?.isRead == true)
        store.loadMore()
        try await waitUntil { store.entries.count == 70 && !store.isLoadingMore }
        XCTAssertEqual(store.entries.map { Int($0.id)! }, Array(11...80))
        withExtendedLifetime(observation) {}
    }
}
