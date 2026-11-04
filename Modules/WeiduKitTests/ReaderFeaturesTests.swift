import XCTest
import Combine
import CryptoKit
import UIKit
@testable import WeiduKit

private actor FetchGate {
    var calls = 0
    private var continuation: CheckedContinuation<String, Never>?
    private var released = false
    func fetch() async -> String {
        calls += 1
        if released { return "<p>抓取正文独有标记，完整的长文章。</p>" }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { released = true; continuation?.resume(returning: "<p>抓取正文独有标记，完整的长文章。</p>"); continuation = nil }
}

final class ReaderFeaturesTests: XCTestCase {
    func testListSnapshotPreservesOrderDayBoundariesAndUnreadCounts() {
        let db = database()
        var items = seed(db)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        items[0].publishedAt = Date(timeIntervalSince1970: 172800)
        items[1].publishedAt = Date(timeIntervalSince1970: 172799)
        items[1].isRead = true
        let snapshot = ArticleListSnapshot(entries: items, calendar: calendar)
        XCTAssertEqual(snapshot.ids, items.map(\.id))
        XCTAssertEqual(snapshot.groups.count, 2)
        XCTAssertEqual(snapshot.groups.flatMap(\.entries), items)
        XCTAssertEqual(snapshot.unreadCount, 1)
        var undated = items[0]
        undated.id = "undated-last"; undated.publishedAt = nil; undated.fetchedAt = items[0].date
        let repeatedDay = ArticleListSnapshot(entries: items + [undated], calendar: calendar)
        XCTAssertEqual(repeatedDay.groups.count, 3)
        XCTAssertEqual(Set(repeatedDay.groups.map(\.id)).count, 3, "Undated rows ordered last may repeat a date without duplicating a group ID")
    }

    func testReusableDateFormatsHandleBothISOFormsAndDifferentOutputFormats() throws {
        let whole = try XCTUnwrap(Format.parseISODate("2026-11-02T10:11:12Z"))
        let fractional = try XCTUnwrap(Format.parseISODate("2026-11-02T10:11:12.125Z"))
        XCTAssertEqual(fractional.timeIntervalSince(whole), 0.125, accuracy: 0.001)
        XCTAssertNil(Format.parseISODate("invalid"))
        XCTAssertNil(Format.parseISODate(""))
        for _ in 0..<10 {
            XCTAssertEqual(Format.parseISODate("2026-11-02T10:11:12Z"), whole)
            XCTAssertEqual(Format.string(whole, format: "yyyy"), "2026")
            XCTAssertEqual(Format.string(whole, format: "M月d日"), "11月2日")
        }
    }

    @MainActor func testScrollReadPublishesOneBatchAndKeepsCountsInSync() {
        let db = database()
        let items = seed(db)
        let other = db.insertFeed(url: "https://other.example.com/rss", title: "另一订阅")!
        _ = db.upsert(entries: [ParsedEntry(guid: "other", title: "保留未读", url: "https://other.example.com/1", author: "", summary: "", contentHTML: "", imageURL: "", publishedAt: Date())], feedID: other.id, fetchedAt: Date())
        let store = store(db)
        store.settings.autoReadOnScroll = true
        let order = store.entries.map(\.id)
        var entryUpdates = 0
        let observation = store.$entries.dropFirst().sink { _ in entryUpdates += 1 }
        let passed = Set(items.map(\.id))
        store.markScrolledEntriesRead(passed)
        XCTAssertEqual(entryUpdates, 1, "A batch must not invalidate the list once per article")
        XCTAssertEqual(store.entries.map(\.id), order)
        XCTAssertEqual(store.unreadTotal, 1)
        XCTAssertEqual(store.feeds, db.allFeeds())
        XCTAssertEqual(store.feeds.first { $0.id == other.id }?.unreadCount, 1)
        XCTAssertTrue(items.allSatisfy { db.entry(id: $0.id)?.isRead == true })
        store.markScrolledEntriesRead(passed)
        XCTAssertEqual(entryUpdates, 1, "Already read IDs must not trigger another list update")
        XCTAssertEqual(store.unreadTotal, db.totals().unread)
        withExtendedLifetime(observation) {}
    }

    func testThumbnailDownsamplesReusesDecodedPixelsAndClearsMemoryCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Thumbnail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = "https://fixture.example.com/large.jpg", referer = "https://fixture.example.com/post"
        let key = SHA256.hash(data: Data((url + "|" + referer).utf8)).map { String(format: "%02x", $0) }.joined()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1600), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        }
        let file = folder.appendingPathComponent(key)
        try data.write(to: file)
        let cache = ImageCache(directory: folder)
        let first = try await cache.thumbnail(url: url, referer: referer, pixelSize: 216)
        XCTAssertEqual(first.cgImage?.width, 216)
        XCTAssertEqual(first.cgImage?.height, 144)
        let second = try await cache.thumbnail(url: url, referer: referer, pixelSize: 216)
        XCTAssertTrue(first === second, "Returning to a row should reuse its decoded thumbnail")
        try await cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try data.write(to: file)
        let afterClear = try await cache.thumbnail(url: url, referer: referer, pixelSize: 216)
        XCTAssertFalse(first === afterClear, "Manual image cleanup also evicts decoded thumbnails")
    }

    private func database() -> Database {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderFeatures-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Database(url: folder.appendingPathComponent("test.sqlite3"))
    }

    private func seed(_ db: Database) -> [Entry] {
        let feed = db.insertFeed(url: "https://fixture.example.com/rss", title: "测试订阅")!
        _ = db.upsert(entries: (1...2).map { index in
            ParsedEntry(guid: "item-\(index)", title: "测试文章第\(index)篇", url: "https://fixture.example.com/\(index)", author: "", summary: "摘要",
                        contentHTML: "<p>订阅源原文第\(index)篇，原始内容。</p>", imageURL: "", publishedAt: Date().addingTimeInterval(-Double(index * 60)))
        }, feedID: feed.id, fetchedAt: Date())
        return db.entries(scope: .articles, unreadOnly: false, search: "", cursor: nil, limit: 10)
    }

    @MainActor private func store(_ db: Database, gate: FetchGate? = nil) -> Store {
        let store = Store(database: db, fulltextFetcher: { _, _ in
            if let gate { return await gate.fetch() }
            throw WeiduError.fulltextUnavailable
        })
        store.settings.markReadOnOpen = false
        store.settings.autoReadOnScroll = false
        store.settings.cacheCleanupDays = 0
        store.settings.refreshMinutes = 0
        return store
    }

    func testSettingsMigrationPreservesOldPreferencesAndAddsSafeDefaults() throws {
        let old = Data("{\"readingSize\":20,\"readingMargin\":32,\"markReadOnOpen\":false}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(settings.readingSize, 20)
        XCTAssertEqual(settings.readingMargin, 32)
        XCTAssertFalse(settings.markReadOnOpen)
        XCTAssertFalse(settings.autoReadOnScroll)
        XCTAssertEqual(settings.cacheCleanupDays, 0)
        XCTAssertEqual(settings.accent, .green)
        XCTAssertEqual(settings.listStyle, .card)
        XCTAssertTrue(settings.openInBrowser)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
        let futureStyle = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"readingSize":20,"listStyle":"future-style"}"#.utf8))
        XCTAssertEqual(futureStyle.listStyle, .card)
        XCTAssertEqual(futureStyle.readingSize, 20)
    }

    func testReaderTitleLinksToOriginalAndUsesSelectedAccent() {
        let db = database()
        var entry = db.entry(id: seed(db)[0].id)!
        var settings = AppSettings()
        settings.accent = .blue
        let html = ReaderHTML.document(entry: entry, settings: settings)
        XCTAssertTrue(html.contains("<h1><a href=\"https://fixture.example.com/1\">测试文章第1篇</a></h1>"))
        XCTAssertTrue(html.contains("--accent:#2e5f8a"))
        entry.url = ""
        XCTAssertTrue(ReaderHTML.document(entry: entry, settings: settings).contains("<h1>测试文章第1篇</h1>"))
    }

    func testDatabaseMigrationAndCacheClearPreserveOriginalsAndState() throws {
        let db = database()
        let entries = seed(db)
        let first = entries[0]
        db.markRead(id: first.id, read: true)
        db.markStarred(id: first.id, starred: true)
        db.setAutoFulltext(feedID: first.feedID, enabled: true)
        db.setFulltext(id: first.id, html: "<p>下载的正文缓存</p>")
        XCTAssertEqual(db.fulltextCacheUsage().count, 1)
        XCTAssertGreaterThan(db.fulltextCacheUsage().bytes, 0)
        let reopened = Database(url: db.fileURL)
        XCTAssertTrue(reopened.feed(id: first.feedID)!.autoFulltext)
        try reopened.clearFulltextCache()
        reopened.compact()
        XCTAssertEqual(db.fulltextCacheUsage(), .zero)
        let after = db.entry(id: first.id)!
        XCTAssertEqual(after.contentHTML, "<p>订阅源原文第1篇，原始内容。</p>")
        XCTAssertTrue(after.isRead && after.isStarred)
        XCTAssertFalse(after.hasFulltext)
        XCTAssertEqual(db.countEntries(feedID: first.feedID), 2)
    }

    func testSourceSwitchAndIdenticalSourceBehavior() {
        let db = database()
        var entry = db.entry(id: seed(db)[0].id)!
        entry.fulltextHTML = "<p>完整正文独有内容</p>"
        let full = ReaderHTML.document(entry: entry, settings: AppSettings())
        let feed = ReaderHTML.document(entry: entry, settings: AppSettings(), showFulltext: false)
        XCTAssertTrue(full.contains("正文来源：原文页抓取"))
        XCTAssertTrue(feed.contains("正文来源：订阅源"))
        XCTAssertTrue(full.contains("完整正文独有内容"))
        XCTAssertFalse(feed.contains("完整正文独有内容"))
        entry.fulltextHTML = entry.contentHTML
        XCTAssertFalse(ReaderHTML.document(entry: entry, settings: AppSettings()).contains("weidu-reader://source"))
    }

    func testExtractionSanitizesAndKeepsOriginalImageURLsUntilRendering() throws {
        let body = String(repeating: "认真阅读这篇文章，留下有价值的观点。", count: 20)
        let html = "<html><body><nav>导航</nav><article><h1>标题</h1><p>\(body)</p><img src='/placeholder.gif' data-src='/real.jpg'><script>alert(1)</script></article></body></html>"
        let extracted = try FulltextExtractor.articleHTML(html, base: "https://fixture.example.com/post", title: "标题")
        XCTAssertFalse(extracted.contains("<script"))
        XCTAssertFalse(extracted.contains("weidu-img://"))
        XCTAssertTrue(extracted.contains("https://fixture.example.com/real.jpg"))
        XCTAssertFalse(extracted.contains("placeholder"))
        XCTAssertThrowsError(try FulltextExtractor.articleHTML("<body>太短</body>", base: "https://fixture.example.com", title: ""))
        XCTAssertTrue(FulltextExtractor.looksChallenged("<div>cf-chl challenge-platform</div>"))
    }

    func testAutoReadRequiresPreviouslyVisibleAndFullyPassedRows() {
        var policy = ListAutoReadPolicy()
        policy.record(id: "seen", top: 10, bottom: 100, viewportTop: 0, viewportBottom: 500)
        policy.record(id: "unseen", top: -200, bottom: -100, viewportTop: 0, viewportBottom: 500)
        XCTAssertTrue(policy.passed(above: 50).isEmpty)
        XCTAssertEqual(policy.passed(above: 100), ["seen"])
        policy.consume(["seen"])
        XCTAssertTrue(policy.passed(above: 500).isEmpty)
    }

    @MainActor func testBottomSweepOnlyMarksCurrentSearchAndRetainsRows() async throws {
        let db = database()
        let entries = seed(db), store = store(db)
        store.settings.autoReadOnScroll = true
        store.setScope(.feed(entries[0].feedID))
        store.searchText = "第1篇"
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(store.entries.map(\.id), [entries[0].id])
        XCTAssertTrue(store.canSweepListRead)
        store.markRemainingListRead()
        XCTAssertTrue(db.entry(id: entries[0].id)!.isRead)
        XCTAssertFalse(db.entry(id: entries[1].id)!.isRead, "Search-excluded rows remain unread")
        XCTAssertFalse(db.entry(id: entries[0].id)!.opened, "Sweeping is not opening an article")
        XCTAssertEqual(store.entries.map(\.id), [entries[0].id])
        XCTAssertTrue(store.entries[0].isRead)
        XCTAssertFalse(store.canSweepListRead)
        let banner = store.banner?.id
        store.markRemainingListRead()
        XCTAssertEqual(store.banner?.id, banner, "An already-read list cannot commit twice")
    }

    @MainActor func testBottomSweepDisabledOrWithMorePagesDoesNotMarkAnything() {
        let db = database()
        let entries = seed(db), store = store(db)
        store.markRemainingListRead()
        XCTAssertEqual(db.totals().unread, 2)
        let more = (3...45).map { index in
            ParsedEntry(guid: "extra-\(index)", title: "额外文章 \(index)", url: "https://fixture.example.com/extra/\(index)", author: "", summary: "", contentHTML: "<p>正文</p>", imageURL: "", publishedAt: Date().addingTimeInterval(-Double(index * 60)))
        }
        _ = db.upsert(entries: more, feedID: entries[0].feedID, fetchedAt: Date())
        let paginated = self.store(db)
        paginated.settings.autoReadOnScroll = true
        XCTAssertTrue(paginated.hasMore)
        XCTAssertFalse(paginated.canSweepListRead)
        paginated.markRemainingListRead()
        XCTAssertEqual(db.totals().unread, 45, "Unloaded pages must never be swept")
    }

    func testMediaSanitizationProducesSafeNativeControls() {
        let db = database()
        var entry = db.entry(id: seed(db)[0].id)!
        entry.contentHTML = "<a href='/large.jpg'><img src='/small.jpg' alt='测试配图'></a><video src='/clip.mp4' poster='/cover.jpg'></video><audio><source src='/sound.mp3'></audio><video src='javascript:alert(1)'></video><iframe src='https://video.example.com/embed/1'></iframe>"
        let rendered = ReaderHTML.document(entry: entry, settings: AppSettings())
        let images = ReaderMedia.images(in: rendered)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].largeURL, "https://fixture.example.com/large.jpg")
        XCTAssertTrue(rendered.contains("weidu-reader://video"))
        XCTAssertTrue(rendered.contains("播放视频"))
        XCTAssertTrue(rendered.contains("播放音频"))
        XCTAssertTrue(rendered.contains("在原站观看视频"))
        XCTAssertFalse(rendered.contains("javascript:"))
        XCTAssertFalse(rendered.contains("<iframe"))
    }

    func testImageCacheClearOnlyRemovesOwnedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImageFeatures-" + UUID().uuidString)
        let owned = folder.appendingPathComponent("images")
        let cache = ImageCache(directory: owned)
        let other = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: other)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: owned.appendingPathComponent("image"))
        let before = await cache.usage()
        XCTAssertEqual(before, CacheUsage(count: 1, bytes: 4))
        try await cache.clear()
        let after = await cache.usage()
        XCTAssertEqual(after, .zero)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    @MainActor func testDuplicateFulltextRequestsAndStaleResponses() async throws {
        let db = database(), gate = FetchGate()
        let entries = seed(db), store = store(db, gate: gate)
        store.open(entries[0])
        let first = Task { await store.extractFulltext() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let duplicate = Task { await store.extractFulltext() }
        try await Task.sleep(nanoseconds: 20_000_000)
        store.open(entries[1])
        XCTAssertFalse(store.readerLoadingFulltext)
        await gate.finish()
        await first.value; await duplicate.value
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.readerEntry?.id, entries[1].id)
        XCTAssertFalse(store.readerHTML.contains("抓取正文独有标记"))
        XCTAssertTrue(db.entry(id: entries[0].id)!.hasFulltext)
        XCTAssertNil(store.banner)
        store.open(entries[0])
        await store.extractFulltext()
        let cachedCalls = await gate.calls
        XCTAssertEqual(cachedCalls, 1, "Cached fulltext must not hit the network again")
    }

    @MainActor func testClearDuringFulltextRequestCannotRepopulateCache() async throws {
        let db = database(), gate = FetchGate()
        let entries = seed(db), store = store(db, gate: gate)
        store.open(entries[0])
        let fetch = Task { await store.extractFulltext() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.clearCaches(.articles)
        await gate.finish()
        await fetch.value
        XCTAssertFalse(db.entry(id: entries[0].id)!.hasFulltext)
        XCTAssertFalse(store.readerLoadingFulltext)
        XCTAssertEqual(store.articleCacheUsage, .zero)
    }

    @MainActor func testReopeningArticleWhileRequestFinishesClearsLoadingIndicator() async throws {
        let db = database(), gate = FetchGate()
        let entries = seed(db), store = store(db, gate: gate)
        store.open(entries[0])
        let fetch = Task { await store.extractFulltext() }
        try await Task.sleep(nanoseconds: 20_000_000)
        store.closeReader()
        store.open(entries[0])
        await gate.finish()
        await fetch.value
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(store.readerEntry!.hasFulltext)
        XCTAssertFalse(store.readerLoadingFulltext, "A reused cached response must clear the new session's loading state")
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testAutomaticFulltextAndScrollReadPersistence() async throws {
        let db = database(), gate = FetchGate()
        let entries = seed(db), store = store(db, gate: gate)
        store.setAutoFulltext(store.feeds.first(where: { $0.id == entries[0].feedID })!, enabled: true)
        XCTAssertTrue(store.feeds.first(where: { $0.id == entries[0].feedID })!.autoFulltext)
        store.open(entries[0])
        try await Task.sleep(nanoseconds: 450_000_000)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.finish()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(store.readerEntry!.hasFulltext)
        store.closeReader()
        store.settings.autoReadOnScroll = true
        store.markScrolledEntriesRead([entries[0].id])
        XCTAssertTrue(db.entry(id: entries[0].id)!.isRead)
        XCTAssertTrue(store.entries.contains(where: { $0.id == entries[0].id }), "Auto-read must retain the row")
        store.settings.autoReadOnScroll = false
        store.markScrolledEntriesRead([entries[1].id])
        XCTAssertFalse(db.entry(id: entries[1].id)!.isRead)
    }

    @MainActor func testScheduledCleanupRunsWhenDueAndRespectsDisabledSetting() async {
        let db = database()
        let entries = seed(db), store = store(db)
        store.settings.cacheCleanupDays = 1
        db.setFulltext(id: entries[0].id, html: "<p>缓存</p>")
        await store.maintenanceIfNeeded(now: Date().addingTimeInterval(86390))
        XCTAssertTrue(db.entry(id: entries[0].id)!.hasFulltext)
        await store.maintenanceIfNeeded(now: Date().addingTimeInterval(86410))
        XCTAssertFalse(db.entry(id: entries[0].id)!.hasFulltext)
        XCTAssertNotNil(store.lastCacheCleanupAt)
        store.settings.cacheCleanupDays = 0
        db.setFulltext(id: entries[0].id, html: "<p>再次缓存</p>")
        await store.maintenanceIfNeeded(now: Date().addingTimeInterval(86400 * 60))
        XCTAssertTrue(db.entry(id: entries[0].id)!.hasFulltext)
        XCTAssertTrue(CachePolicy.isDue(days: 7, since: .distantPast, now: Date()))
        XCTAssertFalse(CachePolicy.isDue(days: 0, since: .distantPast, now: Date()))
    }
}
