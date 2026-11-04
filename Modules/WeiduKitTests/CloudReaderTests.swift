import XCTest
import SwiftUI
import Combine
@testable import WeiduKit

final class CloudReaderTests: XCTestCase {
    @MainActor func testCloudScrollReadSavesOneCompleteBatchAndPublishesCountsOnce() throws {
        let connection = WeiduWorkspaceConnection(scope: "read-batch-" + UUID().uuidString, navigation: WeiduNavigation(),
            transport: { _, _, _ in throw URLError(.notConnectedToInternet) }, articleTools: { _, _, _ in AnyView(EmptyView()) })
        defer { try? FileManager.default.removeItem(at: connection.folder) }
        let db = Database.workspaceCache(connection)
        try db.mergeCloudFeeds([.object(["id": .number(1), "url": .string("https://fixture.invalid/rss")])])
        let ids = try db.mergeCloudList((1...4).map { .object(["id": .number(Double($0)), "feed_id": .number(1)]) }, pending: [:], preserveState: false)
        var settings = AppSettings(); settings.autoReadOnScroll = true
        try JSONEncoder().encode(settings).write(to: connection.folder.appendingPathComponent("settings.json"))
        let store = Store(database: db, workspace: connection)
        var countUpdates = 0, rowUpdates = 0
        let counts = store.$unreadTotal.dropFirst().sink { _ in countUpdates += 1 }
        let rows = store.$entries.dropFirst().sink { _ in rowUpdates += 1 }
        let passed = Set(ids.prefix(3)), order = store.entries.map(\.id)
        store.markScrolledEntriesRead(passed)
        XCTAssertEqual(countUpdates, 1)
        XCTAssertEqual(rowUpdates, 1)
        XCTAssertEqual(store.unreadTotal, 1)
        XCTAssertEqual(store.entries.map(\.id), order)
        XCTAssertEqual(store.listSnapshot.ids, order)
        XCTAssertEqual(store.listSnapshot.unreadCount, 1)
        XCTAssertEqual(store.feeds, db.allFeeds())
        let restored = CloudJournal(folder: connection.folder)
        XCTAssertEqual(restored.operations.count, 3)
        for id in passed {
            XCTAssertEqual(restored.state(id)?["read"], .bool(true))
            XCTAssertTrue(db.listEntry(id: id)?.isRead == true)
        }
        store.markScrolledEntriesRead(passed)
        XCTAssertEqual(countUpdates, 1)
        XCTAssertEqual(rowUpdates, 1)
        withExtendedLifetime([counts, rows]) {}
    }

    @MainActor func testJournalBatchMergesStarsAndOldAcknowledgementKeepsNewerReads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = CloudJournal(folder: folder)
        try journal.enqueue(id: "entry:1", path: "/api/weidu/entries/1/state", body: .object(["starred": .bool(true)]))
        let sent = try XCTUnwrap(journal.operations.first)
        try journal.enqueue((1...3).map { CloudOperation(id: "entry:\($0)", revision: UUID(), path: "/api/weidu/entries/\($0)/state", body: .object(["read": .bool(true)])) })
        try journal.acknowledge(sent)
        let restored = CloudJournal(folder: folder)
        XCTAssertEqual(restored.operations.count, 3)
        XCTAssertEqual(restored.state("1")?["starred"], .bool(true))
        XCTAssertEqual(restored.state("1")?["read"], .bool(true))
        try restored.acknowledge(restored.operations)
        XCTAssertTrue(CloudJournal(folder: folder).operations.isEmpty)
    }

    func testCloudListTransactionRollsBackAndBulkRowsKeepBodiesOutOfList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = Database(url: folder.appendingPathComponent("reader.sqlite3"))
        try db.mergeCloudFeeds([.object(["id": .number(1), "url": .string("https://fixture.invalid/rss")])])
        var article: CloudValue = .object(["id": .number(1), "feed_id": .number(1), "title": .string("Before"), "feed_html": .string("source"), "content_html": .string("full"), "has_fulltext": .bool(true)])
        let id = try db.mergeCloudEntry(article)
        article["title"] = .string("After"); article["feed_html"] = .null; article["content_html"] = .null
        let bad: CloudValue = .object(["id": .number(2), "feed_id": .number(999)])
        XCTAssertThrowsError(try db.mergeCloudList([article, bad], pending: [:], preserveState: false))
        XCTAssertEqual(db.entry(id: id)?.title, "Before")
        XCTAssertNil(db.listEntry(id: Database.cloudID(bad)))
        let ids = try db.mergeCloudList([article], pending: [id: .object(["read": .bool(true), "starred": .bool(true)])], preserveState: false)
        _ = try db.mergeCloudList([article], pending: [:], preserveState: true)
        let rows = db.listEntries(ids: ids + ids + ["absent"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "After")
        XCTAssertTrue(rows.first?.isRead == true)
        XCTAssertTrue(rows.first?.isStarred == true)
        XCTAssertEqual(rows.first?.contentHTML, "")
        XCTAssertNil(rows.first?.fulltextHTML)
        XCTAssertEqual(db.entry(id: id)?.contentHTML, "source")
        XCTAssertEqual(db.entry(id: id)?.fulltextHTML, "full")
    }

    @MainActor func testListStyleSurvivesCloudCacheRestartWithoutQueuingServerPreferences() throws {
        let connection = WeiduWorkspaceConnection(scope: "list-style-" + UUID().uuidString, navigation: WeiduNavigation(),
            transport: { _, _, _ in throw URLError(.notConnectedToInternet) }, articleTools: { _, _, _ in AnyView(EmptyView()) })
        defer { try? FileManager.default.removeItem(at: connection.folder) }
        let store = Store(workspace: connection)
        store.settings.listStyle = .plain
        XCTAssertEqual(store.pendingCloudWrites, 0)
        let restored = Store(workspace: connection)
        XCTAssertEqual(restored.settings.listStyle, .plain)
        XCTAssertEqual(restored.pendingCloudWrites, 0)
    }

    @MainActor func testJournalSurvivesRestartAndOldAcknowledgementKeepsNewerEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = CloudJournal(folder: folder)
        try journal.enqueue(id: "entry:1", path: "/api/weidu/entries/1/state", body: .object(["read": .bool(true)]))
        let sent = try XCTUnwrap(journal.operations.first)
        try journal.enqueue(id: "entry:1", path: sent.path, body: .object(["read": .bool(false), "starred": .bool(true)]))
        try journal.acknowledge(sent)
        let restored = CloudJournal(folder: folder)
        XCTAssertEqual(restored.operations.count, 1)
        XCTAssertEqual(restored.state("1")?["read"], .bool(false))
        XCTAssertEqual(restored.state("1")?["starred"], .bool(true))
        try restored.acknowledge(restored.operations)
        XCTAssertTrue(CloudJournal(folder: folder).operations.isEmpty)
    }

    @MainActor func testUnreadableJournalCannotBeReplacedByAnEmptyQueue() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("pending-states.json"), original = Data("damaged".utf8)
        try original.write(to: file)
        let journal = CloudJournal(folder: folder)
        XCTAssertNotNil(journal.loadFailure)
        XCTAssertThrowsError(try journal.enqueue(id: "entry:1", path: "/api/weidu/entries/1/state", body: .object(["read": .bool(true)])))
        XCTAssertThrowsError(try journal.enqueue([CloudOperation(id: "entry:2", revision: UUID(), path: "/api/weidu/entries/2/state", body: .object(["read": .bool(true)]))]))
        XCTAssertTrue(journal.operations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor func testAccountCacheScopesAndFeedSelection() {
        let navigation = WeiduNavigation()
        func connection(_ scope: String) -> WeiduWorkspaceConnection {
            WeiduWorkspaceConnection(scope: scope, navigation: navigation, transport: { _, _, _ in Data() }, articleTools: { _, _, _ in AnyView(EmptyView()) })
        }
        XCTAssertNotEqual(connection("server|alice").folder, connection("server|bob").folder)
        XCTAssertNotEqual(connection("server|alice").folder, connection("other-server|alice").folder)
        XCTAssertEqual(connection("server|alice").folder, connection("server|alice").folder)
        navigation.selectFeeds([10, 2]); XCTAssertEqual(navigation.feedSelection, [10, 2])
        navigation.openFeed(7);XCTAssertEqual(navigation.feed, "7");XCTAssertEqual(navigation.feedSelection, [10, 2])
        navigation.openArticle(42); XCTAssertEqual(navigation.article, "42")
    }

    @MainActor func testCloudScrollEndDoesNotMarkAnythingWhenAutoReadIsOff() throws {
        let connection = WeiduWorkspaceConnection(scope: "test-" + UUID().uuidString, navigation: WeiduNavigation(),
            transport: { _, _, _ in throw URLError(.notConnectedToInternet) }, articleTools: { _, _, _ in AnyView(EmptyView()) })
        defer { try? FileManager.default.removeItem(at: connection.folder) }
        let database = Database.workspaceCache(connection)
        try database.mergeCloudFeeds([.object(["id": .number(1), "url": .string("https://fixture.invalid/rss")])])
        let id = try database.mergeCloudEntry(.object(["id": .number(1), "feed_id": .number(1)]))
        let store = Store(database: database, workspace: connection)
        store.settings.autoReadOnScroll = false
        store.markRemainingListRead()
        XCTAssertEqual(database.entry(id: id)?.isRead, false)
        XCTAssertEqual(store.pendingCloudWrites, 0)
        store.settings.autoReadOnScroll = true
        store.markRemainingListRead()
        XCTAssertEqual(database.entry(id: id)?.isRead, true)
        XCTAssertGreaterThan(store.pendingCloudWrites, 0)
    }

    @MainActor func testCloudCachePreservesFullBodyAcrossLightListRefresh() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = Database(url: folder.appendingPathComponent("reader.sqlite3"))
        let feed: CloudValue = .object(["id": .number(7), "url": .string("https://fixture.invalid/rss"), "title": .string("Fixture")])
        try database.mergeCloudFeeds([feed])
        var article: CloudValue = .object(["id": .number(42), "feed_id": .number(7), "title": .string("Article"), "content_html": .string("full"), "feed_html": .string("source"), "has_fulltext": .bool(true)])
        let id = try database.mergeCloudEntry(article)
        article["content_html"] = .null; article["feed_html"] = .null
        _ = try database.mergeCloudEntry(article, pending: .object(["read": .bool(true), "starred": .bool(true)]))
        XCTAssertEqual(database.entry(id: id)?.contentHTML, "source")
        XCTAssertEqual(database.entry(id: id)?.fulltextHTML, "full")
        XCTAssertEqual(database.entry(id: id)?.isRead, true)
        XCTAssertEqual(database.entry(id: id)?.isStarred, true)
        // Rows need metadata only; opening the article must still retain both bodies.
        let row = try XCTUnwrap(database.listEntry(id: id))
        XCTAssertEqual(row.title, "Article")
        XCTAssertEqual(row.contentHTML, "")
        XCTAssertNil(row.fulltextHTML)
        XCTAssertTrue(row.isRead)
        XCTAssertTrue(row.isStarred)
        // A GET sent before a state ACK may return after the journal is empty.
        _ = try database.mergeCloudEntry(article, preserveState: true)
        XCTAssertEqual(database.entry(id: id)?.isRead, true)
        XCTAssertEqual(database.entry(id: id)?.isStarred, true)
        // A later fresh snapshot can still reflect a different device's change.
        _ = try database.mergeCloudEntry(article)
        XCTAssertEqual(database.entry(id: id)?.isRead, false)
        XCTAssertEqual(database.entry(id: id)?.isStarred, false)
        try database.mergeCloudFeeds([]); XCTAssertNil(database.entry(id: id))
    }
}
