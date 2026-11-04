import Foundation
import SQLite3

private let SQL_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum SQLArg {
    case text(String)
    case int(Int)
    case double(Double)
    case null
}

final class Database {
    private var handle: OpaquePointer?
    let fileURL: URL

    init(url: URL? = nil) {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Weidu", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = url ?? base.appendingPathComponent("weidu.sqlite3")
        let path = fileURL.path

        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            fatalError("打不开本地数据库：\(message)")
        }
        sqlite3_busy_timeout(handle, 3000)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA foreign_keys=ON;")
        migrate()
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    // MARK: - 基础

    private func exec(_ sql: String) {
        guard let handle else { return }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            if let error {
                print("[weidu] sqlite: \(String(cString: error))")
                sqlite3_free(error)
            }
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let handle else { return nil }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK {
            print("[weidu] prepare failed: \(String(cString: sqlite3_errmsg(handle))) sql=\(sql)")
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQL_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindArgs(_ stmt: OpaquePointer?, _ args: [SQLArg]) {
        for (offset, arg) in args.enumerated() {
            let index = Int32(offset + 1)
            switch arg {
            case .text(let value): bind(stmt, index, value)
            case .int(let value): sqlite3_bind_int64(stmt, index, Int64(value))
            case .double(let value): sqlite3_bind_double(stmt, index, value)
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func optionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return text(stmt, index)
    }

    private func int(_ stmt: OpaquePointer?, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    private func double(_ stmt: OpaquePointer?, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    private func optionalDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: double(stmt, index))
    }

    private func like(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS feeds (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            site_url TEXT NOT NULL DEFAULT '',
            icon_url TEXT NOT NULL DEFAULT '',
            category TEXT NOT NULL DEFAULT '',
            sort INTEGER NOT NULL DEFAULT 0,
            added_at REAL NOT NULL,
            last_fetch_at REAL,
            last_error TEXT,
            etag TEXT NOT NULL DEFAULT '',
            last_modified TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS entries (
            id TEXT PRIMARY KEY,
            feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
            guid TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            url TEXT NOT NULL DEFAULT '',
            author TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL DEFAULT '',
            content_html TEXT NOT NULL DEFAULT '',
            fulltext_html TEXT,
            image_url TEXT NOT NULL DEFAULT '',
            published_at REAL,
            fetched_at REAL NOT NULL,
            is_read INTEGER NOT NULL DEFAULT 0,
            is_starred INTEGER NOT NULL DEFAULT 0,
            opened INTEGER NOT NULL DEFAULT 0,
            UNIQUE(feed_id, guid)
        );
        CREATE INDEX IF NOT EXISTS idx_entries_feed ON entries(feed_id, published_at DESC);
        CREATE INDEX IF NOT EXISTS idx_entries_read ON entries(is_read, published_at DESC);
        CREATE INDEX IF NOT EXISTS idx_entries_star ON entries(is_starred, published_at DESC);
        PRAGMA user_version=1;
        """)
        if let columns = prepare("PRAGMA table_info(feeds)") {
            var hasAutoFulltext = false
            while sqlite3_step(columns) == SQLITE_ROW {
                if text(columns, 1) == "auto_fulltext" { hasAutoFulltext = true }
            }
            sqlite3_finalize(columns)
            if !hasAutoFulltext { exec("ALTER TABLE feeds ADD COLUMN auto_fulltext INTEGER NOT NULL DEFAULT 0;") }
        }
    }

    // MARK: - 订阅

    private static let feedColumns = "f.id,f.url,f.title,f.site_url,f.icon_url,f.category,f.sort,f.added_at,f.last_fetch_at,f.last_error,f.etag,f.last_modified,(SELECT COUNT(*) FROM entries e WHERE e.feed_id=f.id AND e.is_read=0),f.auto_fulltext"

    private func makeFeed(_ stmt: OpaquePointer?) -> Feed {
        Feed(
            id: text(stmt, 0),
            url: text(stmt, 1),
            title: text(stmt, 2),
            siteURL: text(stmt, 3),
            iconURL: text(stmt, 4),
            category: text(stmt, 5),
            sort: int(stmt, 6),
            addedAt: Date(timeIntervalSince1970: double(stmt, 7)),
            lastFetchAt: optionalDate(stmt, 8),
            lastError: optionalText(stmt, 9),
            etag: text(stmt, 10),
            lastModified: text(stmt, 11),
            unreadCount: int(stmt, 12),
            autoFulltext: int(stmt, 13) != 0
        )
    }

    func allFeeds() -> [Feed] {
        guard let stmt = prepare("SELECT \(Database.feedColumns) FROM feeds f ORDER BY f.sort, f.title") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [Feed] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(makeFeed(stmt))
        }
        return result
    }

    func feed(id: String) -> Feed? {
        guard let stmt = prepare("SELECT \(Database.feedColumns) FROM feeds f WHERE f.id=? LIMIT 1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return makeFeed(stmt)
    }

    func feed(url: String) -> Feed? {
        guard let stmt = prepare("SELECT \(Database.feedColumns) FROM feeds f WHERE f.url=? LIMIT 1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, url)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return makeFeed(stmt)
    }

    @discardableResult
    func insertFeed(url: String, title: String) -> Feed? {
        if feed(url: url) != nil { return nil }
        var nextSort = 0
        if let stmt = prepare("SELECT COALESCE(MAX(sort),-1)+1 FROM feeds") {
            if sqlite3_step(stmt) == SQLITE_ROW { nextSort = int(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        let id = UUID().uuidString
        let host = URL(string: url)?.host ?? url
        guard let stmt = prepare("INSERT INTO feeds (id,url,title,added_at,sort) VALUES (?,?,?,?,?)") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        bind(stmt, 2, url)
        bind(stmt, 3, title.isEmpty ? host : title)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 5, Int64(nextSort))
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return feed(id: id)
    }

    func updateFeedMeta(id: String, title: String, siteURL: String, iconURL: String) {
        guard let stmt = prepare("UPDATE feeds SET title=CASE WHEN ?='' THEN title ELSE ? END, site_url=CASE WHEN ?='' THEN site_url ELSE ? END, icon_url=CASE WHEN ?='' THEN icon_url ELSE ? END WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, title)
        bind(stmt, 2, title)
        bind(stmt, 3, siteURL)
        bind(stmt, 4, siteURL)
        bind(stmt, 5, iconURL)
        bind(stmt, 6, iconURL)
        bind(stmt, 7, id)
        sqlite3_step(stmt)
    }

    func updateFetchState(id: String, etag: String, lastModified: String, error: String?) {
        guard let stmt = prepare("UPDATE feeds SET last_fetch_at=?, etag=CASE WHEN ?='' THEN etag ELSE ? END, last_modified=CASE WHEN ?='' THEN last_modified ELSE ? END, last_error=? WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        bind(stmt, 2, etag)
        bind(stmt, 3, etag)
        bind(stmt, 4, lastModified)
        bind(stmt, 5, lastModified)
        bind(stmt, 6, error)
        bind(stmt, 7, id)
        sqlite3_step(stmt)
    }

    func deleteFeed(id: String) {
        guard let stmt = prepare("DELETE FROM feeds WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        sqlite3_step(stmt)
    }

    // MARK: - 文章

    private static let listColumns = "e.id,e.feed_id,f.title,e.title,e.url,e.author,e.summary,e.image_url,e.published_at,e.fetched_at,e.is_read,e.is_starred,e.opened,COALESCE(e.published_at,e.fetched_at)"

    private func makeEntry(_ stmt: OpaquePointer?) -> Entry {
        Entry(
            id: text(stmt, 0),
            feedID: text(stmt, 1),
            feedTitle: text(stmt, 2),
            title: text(stmt, 3),
            url: text(stmt, 4),
            author: text(stmt, 5),
            summary: text(stmt, 6),
            contentHTML: "",
            fulltextHTML: nil,
            imageURL: text(stmt, 7),
            publishedAt: optionalDate(stmt, 8),
            fetchedAt: Date(timeIntervalSince1970: double(stmt, 9)),
            isRead: int(stmt, 10) != 0,
            isStarred: int(stmt, 11) != 0,
            opened: int(stmt, 12) != 0,
            sortTime: double(stmt, 13)
        )
    }

    func entries(scope: ListScope, unreadOnly: Bool, search: String, cursor: (time: Double, id: String)?, limit: Int, retainedReadIDs: Set<String> = [], feedIDs: [String] = []) -> [Entry] {
        var whereParts: [String] = []
        var args: [SQLArg] = []
        if !feedIDs.isEmpty, case .feed = scope { } else if !feedIDs.isEmpty {
            whereParts.append("e.feed_id IN (" + feedIDs.map { _ in "?" }.joined(separator: ",") + ")")
            args.append(contentsOf: feedIDs.map(SQLArg.text))
        }

        switch scope {
        case .articles:
            break
        case .starred:
            whereParts.append("e.is_starred=1")
        case .feed(let feedID):
            whereParts.append("e.feed_id=?")
            args.append(.text(feedID))
        }
        if unreadOnly && scope != .starred {
            if retainedReadIDs.isEmpty {
                whereParts.append("e.is_read=0")
            } else {
                let ids = retainedReadIDs.sorted()
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                whereParts.append("(e.is_read=0 OR e.id IN (\(placeholders)))")
                args.append(contentsOf: ids.map { .text($0) })
            }
        }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            whereParts.append("(e.title LIKE ? ESCAPE '\\' OR e.summary LIKE ? ESCAPE '\\')")
            let pattern = like(trimmed)
            args.append(.text(pattern))
            args.append(.text(pattern))
        }
        if let cursor {
            whereParts.append("(COALESCE(e.published_at,e.fetched_at) < ? OR (COALESCE(e.published_at,e.fetched_at) = ? AND e.id < ?))")
            args.append(.double(cursor.time))
            args.append(.double(cursor.time))
            args.append(.text(cursor.id))
        }
        let whereSQL = whereParts.isEmpty ? "" : "WHERE " + whereParts.joined(separator: " AND ")
        let sql = "SELECT \(Database.listColumns) FROM entries e JOIN feeds f ON f.id=e.feed_id \(whereSQL) ORDER BY COALESCE(e.published_at,e.fetched_at) DESC, e.id DESC LIMIT ?"
        args.append(.int(limit))

        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args)
        var result: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(makeEntry(stmt))
        }
        return result
    }

    func listEntry(id: String) -> Entry? {
        guard let stmt = prepare("SELECT \(Database.listColumns) FROM entries e JOIN feeds f ON f.id=e.feed_id WHERE e.id=? LIMIT 1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return makeEntry(stmt)
    }

    func listEntries(ids: [String]) -> [Entry] {
        var result: [Entry] = []
        // Stay below SQLite's bind-variable limit even for a long live prefix.
        let unique = Array(Set(ids))
        for start in stride(from: 0, to: unique.count, by: 400) {
            let chunk = Array(unique.dropFirst(start).prefix(400))
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            guard let stmt = prepare("SELECT \(Database.listColumns) FROM entries e JOIN feeds f ON f.id=e.feed_id WHERE e.id IN (\(placeholders))") else { continue }
            bindArgs(stmt, chunk.map(SQLArg.text))
            while sqlite3_step(stmt) == SQLITE_ROW { result.append(makeEntry(stmt)) }
            sqlite3_finalize(stmt)
        }
        return result
    }

    func entry(id: String) -> Entry? {
        let sql = "SELECT \(Database.listColumns),e.content_html,e.fulltext_html FROM entries e JOIN feeds f ON f.id=e.feed_id WHERE e.id=? LIMIT 1"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var entry = makeEntry(stmt)
        entry.contentHTML = text(stmt, 14)
        entry.fulltextHTML = optionalText(stmt, 15)
        return entry
    }

    func adjacency(after entry: Entry, unreadOnly: Bool) -> Entry? {
        var sql = "SELECT \(Database.listColumns) FROM entries e JOIN feeds f ON f.id=e.feed_id WHERE (COALESCE(e.published_at,e.fetched_at) < ? OR (COALESCE(e.published_at,e.fetched_at) = ? AND e.id < ?))"
        if unreadOnly { sql += " AND e.is_read=0" }
        sql += " ORDER BY COALESCE(e.published_at,e.fetched_at) DESC, e.id DESC LIMIT 1"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, entry.sortTime)
        sqlite3_bind_double(stmt, 2, entry.sortTime)
        bind(stmt, 3, entry.id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return makeEntry(stmt)
    }

    func newerEntry(before entry: Entry) -> Entry? {
        let sql = "SELECT \(Database.listColumns) FROM entries e JOIN feeds f ON f.id=e.feed_id WHERE (COALESCE(e.published_at,e.fetched_at) > ? OR (COALESCE(e.published_at,e.fetched_at) = ? AND e.id > ?)) ORDER BY COALESCE(e.published_at,e.fetched_at) ASC, e.id ASC LIMIT 1"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, entry.sortTime)
        sqlite3_bind_double(stmt, 2, entry.sortTime)
        bind(stmt, 3, entry.id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return makeEntry(stmt)
    }

    @discardableResult
    func upsert(entries items: [ParsedEntry], feedID: String, fetchedAt: Date) -> Int {
        let before = countEntries(feedID: feedID)
        exec("BEGIN IMMEDIATE;")
        let sql = """
        INSERT INTO entries (id,feed_id,guid,title,url,author,summary,content_html,image_url,published_at,fetched_at,is_read,is_starred,opened)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,0,0,0)
        ON CONFLICT(feed_id,guid) DO UPDATE SET
            title=excluded.title,
            url=excluded.url,
            author=excluded.author,
            summary=excluded.summary,
            content_html=excluded.content_html,
            image_url=excluded.image_url,
            published_at=COALESCE(excluded.published_at,entries.published_at),
            fetched_at=excluded.fetched_at
        """
        for item in items {
            guard let stmt = prepare(sql) else { continue }
            bind(stmt, 1, UUID().uuidString)
            bind(stmt, 2, feedID)
            bind(stmt, 3, item.guid)
            bind(stmt, 4, item.title)
            bind(stmt, 5, item.url)
            bind(stmt, 6, item.author)
            bind(stmt, 7, item.summary)
            bind(stmt, 8, item.contentHTML)
            bind(stmt, 9, item.imageURL)
            if let date = item.publishedAt {
                sqlite3_bind_double(stmt, 10, date.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_double(stmt, 11, fetchedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;")
        let after = countEntries(feedID: feedID)
        return max(0, after - before)
    }

    func countEntries(feedID: String) -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM entries WHERE feed_id=?") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, feedID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return int(stmt, 0)
    }

    func markRead(id: String, read: Bool) {
        guard let stmt = prepare("UPDATE entries SET is_read=? WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, read ? 1 : 0)
        bind(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func markStarred(id: String, starred: Bool) {
        guard let stmt = prepare("UPDATE entries SET is_starred=? WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, starred ? 1 : 0)
        bind(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func markOpened(id: String) {
        guard let stmt = prepare("UPDATE entries SET opened=1 WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        sqlite3_step(stmt)
    }

    @discardableResult
    func markAllRead(scope: ListScope) -> Int {
        guard let handle else { return 0 }
        let sql: String
        var args: [SQLArg] = []
        switch scope {
        case .articles:
            sql = "UPDATE entries SET is_read=1 WHERE is_read=0"
        case .starred:
            sql = "UPDATE entries SET is_read=1 WHERE is_read=0 AND is_starred=1"
        case .feed(let feedID):
            sql = "UPDATE entries SET is_read=1 WHERE is_read=0 AND feed_id=?"
            args.append(.text(feedID))
        }
        guard let stmt = prepare(sql) else { return 0 }
        bindArgs(stmt, args)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return Int(sqlite3_changes(handle))
    }

    func setFulltext(id: String, html: String) {
        guard let stmt = prepare("UPDATE entries SET fulltext_html=? WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, html)
        bind(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func setAutoFulltext(feedID: String, enabled: Bool) {
        guard let stmt = prepare("UPDATE feeds SET auto_fulltext=? WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
        bind(stmt, 2, feedID)
        sqlite3_step(stmt)
    }

    func markRead(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        guard let stmt = prepare("UPDATE entries SET is_read=1 WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        exec("BEGIN IMMEDIATE;")
        for id in ids {
            sqlite3_reset(stmt)
            bind(stmt, 1, id)
            sqlite3_step(stmt)
        }
        exec("COMMIT;")
    }

    func fulltextCacheUsage() -> CacheUsage {
        guard let stmt = prepare("SELECT COUNT(*),COALESCE(SUM(LENGTH(CAST(fulltext_html AS BLOB))),0) FROM entries WHERE fulltext_html IS NOT NULL AND fulltext_html<>''") else { return .zero }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .zero }
        return CacheUsage(count: int(stmt, 0), bytes: Int64(sqlite3_column_int64(stmt, 1)))
    }

    func clearFulltextCache() throws {
        guard let stmt = prepare("UPDATE entries SET fulltext_html=NULL WHERE fulltext_html IS NOT NULL") else { throw WeiduError.network("无法清理正文缓存") }
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard result == SQLITE_DONE else { throw WeiduError.network("正文缓存清理失败") }
    }

    func compact() {
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
        exec("VACUUM;")
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func totals() -> (unread: Int, starred: Int) {
        let sql = "SELECT (SELECT COUNT(*) FROM entries WHERE is_read=0),(SELECT COUNT(*) FROM entries WHERE is_starred=1)"
        guard let stmt = prepare(sql) else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (int(stmt, 0), int(stmt, 1))
    }

    @discardableResult
    func prune(keepDays: Int) -> Int {
        guard keepDays > 0, let handle else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - Double(keepDays) * 86400
        guard let stmt = prepare("DELETE FROM entries WHERE is_starred=0 AND COALESCE(published_at,fetched_at) < ?") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(handle))
    }
}


extension Database {
    @MainActor static func workspaceCache(_ connection: WeiduWorkspaceConnection) -> Database {
        try? FileManager.default.createDirectory(at: connection.folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        return Database(url: connection.folder.appendingPathComponent("reader.sqlite3"))
    }

    private func cloudWrite(_ sql: String, _ args: [SQLArg] = []) throws {
        guard let stmt = prepare(sql) else { throw WeiduError.network("无法写入阅读缓存") }
        defer { sqlite3_finalize(stmt) }
        bindArgs(stmt, args)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw WeiduError.network("阅读缓存写入失败") }
    }

    func mergeCloudFeeds(_ items: [CloudValue]) throws {
        try cloudWrite("BEGIN IMMEDIATE")
        do {
            let ids = items.map { $0["id"].text }
            if ids.isEmpty { try cloudWrite("DELETE FROM feeds") }
            else { try cloudWrite("DELETE FROM feeds WHERE id NOT IN (" + ids.map { _ in "?" }.joined(separator: ",") + ")", ids.map(SQLArg.text)) }
            for f in items {
                try cloudWrite("""
                INSERT INTO feeds(id,url,title,site_url,icon_url,category,sort,added_at,last_fetch_at,last_error,auto_fulltext)
                VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET url=excluded.url,title=excluded.title,
                site_url=excluded.site_url,icon_url=excluded.icon_url,category=excluded.category,sort=excluded.sort,
                last_fetch_at=excluded.last_fetch_at,last_error=excluded.last_error,auto_fulltext=excluded.auto_fulltext
                """, [.text(f["id"].text),.text(f["url"].text),.text(f["title"].text),.text(f["site_url"].text),.text(f["icon_url"].text),
                .text(f["group"].text),.int(f["sort"].int),.double(Date().timeIntervalSince1970),
                f["last_fetch_at"].date.map { .double($0.timeIntervalSince1970) } ?? .null,
                f["last_error"] == .null ? .null : .text(f["last_error"].text),.int(f["auto_fulltext"].flag ? 1 : 0)])
            }
            try cloudWrite("COMMIT")
        } catch { try? cloudWrite("ROLLBACK"); throw error }
    }

    static func cloudID(_ item: CloudValue) -> String { String(format: "%020lld", Int64(item["id"].int)) }

    func mergeCloudList(_ items: [CloudValue], pending: [String: CloudValue], preserveState: Bool) throws -> [String] {
        guard !items.isEmpty else { return [] }
        try cloudWrite("BEGIN IMMEDIATE")
        do {
            let ids = try items.map { try mergeCloudEntry($0, pending: pending[Self.cloudID($0)], preserveState: preserveState) }
            try cloudWrite("COMMIT")
            return ids
        } catch { try? cloudWrite("ROLLBACK"); throw error }
    }

    func mergeCloudEntry(_ item: CloudValue, pending: CloudValue? = nil, preserveState: Bool = false) throws -> String {
        let id = Self.cloudID(item)
        var state = pending?.object ?? [:]
        if preserveState, let local = listEntry(id: id) {
            if state["read"] == nil { state["read"] = .bool(local.isRead) }
            if state["starred"] == nil { state["starred"] = .bool(local.isStarred) }
        }
        let body = item["content_html"]
        let source = item["feed_html"] == .null ? body : item["feed_html"]
        let fulltext: SQLArg = item["has_fulltext"].flag && body != .null ? .text(body.text) : .null
        let read = state["read"] ?? .null, starred = state["starred"] ?? .null
        try cloudWrite("""
        INSERT INTO entries(id,feed_id,guid,title,url,author,summary,content_html,fulltext_html,image_url,published_at,fetched_at,is_read,is_starred)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET feed_id=excluded.feed_id,title=excluded.title,url=excluded.url,
        author=excluded.author,summary=excluded.summary,content_html=CASE WHEN ? THEN excluded.content_html ELSE entries.content_html END,
        fulltext_html=CASE WHEN ? THEN excluded.fulltext_html ELSE entries.fulltext_html END,image_url=excluded.image_url,
        published_at=excluded.published_at,fetched_at=excluded.fetched_at,is_read=excluded.is_read,is_starred=excluded.is_starred
        """, [.text(id),.text(item["feed_id"].text),.text(item["guid"].text.isEmpty ? item["id"].text : item["guid"].text),
        .text(item["title"].text),.text(item["url"].text),.text(item["author"].text),.text(item["summary"].text),.text(source.text),fulltext,
        .text(item["image_url"].text),item["published_at"].date.map { .double($0.timeIntervalSince1970) } ?? .null,
        .double(item["fetched_at"].date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970),
        .int((read == .null ? item["is_read"].flag : read.flag) ? 1 : 0),
        .int((starred == .null ? item["is_starred"].flag : starred.flag) ? 1 : 0),.int(body == .null ? 0 : 1),.int(body == .null ? 0 : 1)])
        return id
    }
}
