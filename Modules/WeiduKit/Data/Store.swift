import Foundation
import Combine

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

@MainActor
final class Store: ObservableObject {
    private let database: Database
    let workspace: WeiduWorkspaceConnection?
    private let cloudJournal: CloudJournal?
    private var cloudListTask: Task<Void, Never>?
    private var cloudFlushTask: Task<Void, Never>?
    private var cloudListRevision = UUID()
    private var cloudOpenRevision = UUID()
    private var cloudPagination = CloudListPagination()
    private var lastCloudOverviewAt: Date?
    private var preservingListDuringSync = false
    private var cloudFlushing = false
    private var cloudApplyingPrefs = false
    private var cloudOffline = false
    private var cloudCountsTrusted = false
    private var cloudFeedUnread: [String: Int] = [:]
    private var cloudFeedTotals: [String: Int] = [:]
    private var cloudFeedKinds: [String: String] = [:]
    private var cloudStateVersion = 0
    private var cloudContentVersion = 0
    @Published private(set) var pendingCloudWrites = 0
    private let fulltextFetcher: (String, String) async throws -> String
    private let pageSize = 40

    @Published private(set) var feeds: [Feed] = []
    @Published private(set) var entries: [Entry] = [] {
        didSet { listSnapshot = ArticleListSnapshot(entries: entries) }
    }
    private(set) var listSnapshot = ArticleListSnapshot(entries: [])
    @Published private(set) var unreadTotal = 0
    @Published private(set) var starredTotal = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasMore = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var listPageError: String?
    let scrollToTop = PassthroughSubject<AppTab, Never>()
    @Published var banner: Banner?
    @Published var browserRequest: BrowserRequest?
    @Published var readerEntry: Entry?
    @Published private(set) var readerHTML = ""
    @Published private(set) var readerNextPage: ReaderPage?
    @Published private(set) var readerPreviousPage: ReaderPage?
    @Published var readerLoadingFulltext = false
    @Published private(set) var readerLoadingBody = false
    @Published private(set) var readerShowsFulltext = true
    @Published private(set) var articleCacheUsage = CacheUsage.zero
    @Published private(set) var imageCacheUsage = CacheUsage.zero
    @Published private(set) var isClearingCaches = false
    @Published private(set) var lastCacheCleanupAt: Date?
    @Published var selectedTab: AppTab = .articles
    @Published private(set) var listTabBarVisible = true

    @Published var listScope: ListScope = .articles
    @Published var settings: AppSettings {
        didSet {
            if let workspace {
                if let data = try? JSONEncoder().encode(settings) {
                    try? data.write(to: workspace.folder.appendingPathComponent("settings.json"), options: [.atomic, .completeFileProtection])
                }
                if !cloudApplyingPrefs { queueCloudPreferences(previous: oldValue) }
            } else { settings.saved() }
            Theme.accentTheme = settings.accent
            if let entry = readerEntry,
               oldValue.accent != settings.accent || oldValue.readingFont != settings.readingFont || oldValue.readingSize != settings.readingSize || oldValue.readingMargin != settings.readingMargin {
                readerHTML = ReaderHTML.document(entry: entry, settings: settings, showFulltext: readerShowsFulltext)
                prepareReaderNeighbors()
            }
            if !cloudApplyingPrefs, oldValue.listView != settings.listView {
                reloadList()
            }
            if oldValue.keepDays != settings.keepDays {
                if workspace == nil { _ = self.database.prune(keepDays: settings.keepDays) }
                reloadFeeds()
                if !cloudApplyingPrefs { reloadList() }
            }
            if oldValue.cacheCleanupDays != settings.cacheCleanupDays {
                cacheScheduleStart = Date()
                UserDefaults.standard.set(cacheScheduleStart.timeIntervalSince1970, forKey: "weidu.cacheScheduleStart")
            }
        }
    }
    @Published var searchText = "" {
        didSet {
            guard !suppressSearch else { return }
            scheduleSearch()
        }
    }

    private var suppressSearch = false
    private var cursor: (time: Double, id: String)?
    private var searchTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var readTrail: [String] = []
    private var retainedReadIDs: Set<String> = []
    private var hiddenReadIDs: Set<String> = []
    private var readerPreparation: Task<Void, Never>?
    private var readerSession = UUID()
    private var autoFulltextTask: Task<Void, Never>?
    private var fulltextRequests: [String: (id: UUID, task: Task<String, Error>)] = [:]
    private var cacheGeneration = 0
    private var cacheScheduleStart = Date()
    private var maintaining = false

    init(database: Database? = nil, workspace: WeiduWorkspaceConnection? = nil, fulltextFetcher: @escaping (String, String) async throws -> String = { try await FulltextExtractor.shared.extract(url: $0, title: $1) }) {
        self.workspace = workspace
        self.database = database ?? workspace.map { Database.workspaceCache($0) } ?? Database()
        self.cloudJournal = workspace.map { CloudJournal(folder: $0.folder) }
        #if DEBUG
        if DesignPreviewData.requestedScreen == "reader-loading-regression" {
            self.fulltextFetcher = { _, _ in
                try await Task.sleep(nanoseconds: 4_000_000_000)
                return "<p>过渡测试正文，抓取完成后平滑显示。</p><p>订阅源原文仍可切换查看。</p>"
            }
        } else { self.fulltextFetcher = fulltextFetcher }
        #else
        self.fulltextFetcher = fulltextFetcher
        #endif
        if let workspace {
            if let data = try? Data(contentsOf: workspace.folder.appendingPathComponent("settings.json")), let saved = try? JSONDecoder().decode(AppSettings.self, from: data) { settings = saved }
            else { settings = AppSettings() }
        } else { settings = AppSettings.load() }
        Theme.accentTheme = settings.accent
        if let stamp = UserDefaults.standard.object(forKey: "weidu.lastCacheCleanupAt") as? Double { lastCacheCleanupAt = Date(timeIntervalSince1970: stamp) }
        if let stamp = UserDefaults.standard.object(forKey: "weidu.cacheScheduleStart") as? Double { cacheScheduleStart = Date(timeIntervalSince1970: stamp) }
        else { UserDefaults.standard.set(cacheScheduleStart.timeIntervalSince1970, forKey: "weidu.cacheScheduleStart") }
        if let stamp = UserDefaults.standard.object(forKey: "weidu.lastRefreshAt") as? Double {
            lastRefreshAt = Date(timeIntervalSince1970: stamp)
        }
        if workspace == nil { _ = self.database.prune(keepDays: settings.keepDays) }
        pendingCloudWrites = cloudJournal?.operations.count ?? 0
        for op in cloudJournal?.operations ?? [] where op.id.hasPrefix("entry:") {
            let id = String(op.id.dropFirst(6))
            if op.body["read"] != .null { self.database.markRead(id: id, read: op.body["read"].flag) }
            if op.body["starred"] != .null { self.database.markStarred(id: id, starred: op.body["starred"].flag) }
        }
        reloadFeeds()
        if workspace != nil { reloadCloudList(loadRemote: false) }
        else { reloadList() }
        #if DEBUG
        if let screen = DesignPreviewData.requestedScreen {
            settings.refreshMinutes = 0
            settings.listFontSize = 15
            settings.autoReadOnScroll = false
            settings.cacheCleanupDays = 0
            feeds = DesignPreviewData.feeds
            entries = DesignPreviewData.entries
            unreadTotal = 10
            starredTotal = 2
            lastRefreshAt = Date()
            hasMore = false
            switch screen {
            case "scroll-regression": entries = DesignPreviewData.scrollRegressionEntries
            case "starred":
                listScope = .starred
                entries = entries.filter(\.isStarred)
                selectedTab = .starred
            case "feeds": selectedTab = .feeds
            case "settings": selectedTab = .settings
            case "reader":
                if let entry = entries.first {
                    readerEntry = entry
                    readerHTML = ReaderHTML.document(entry: entry, settings: settings)
                }
            case "reader-pull-regression":
                seedReaderRegression()
            case "features-regression", "media-regression", "reader-loading-regression":
                seedFeatureRegression(media: screen == "media-regression")
            case "pagination-regression": seedFeatureRegression(media: false, count: 120)
            default: break
            }
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--reader-list-style"), index + 1 < arguments.count,
               let style = ArticleListStyle(rawValue: arguments[index + 1]) { settings.listStyle = style }
        }
        #endif
        // Direct assignments inside init (including design previews) do not
        // invoke the entries property observer.
        listSnapshot = ArticleListSnapshot(entries: entries)
    }

    // MARK: - 列表

    var listIsUnreadOnly: Bool {
        settings.listView == .unread && listScope != .starred
    }

    var scopeTitle: String {
        switch listScope {
        case .articles: return listIsUnreadOnly ? "未读" : "全部"
        case .starred: return "星标"
        case .feed(let feedID): return feeds.first(where: { $0.id == feedID })?.title ?? "订阅"
        }
    }

    var scopeSubtitle: String {
        if workspace != nil, cloudOffline || pendingCloudWrites > 0 {
            return (cloudOffline ? "本机缓存" : "工作台同步") + " · \(pendingCloudWrites) 项修改待同步"
        }
        switch listScope {
        case .articles:
            let refresh = lastRefreshAt.map { " · 更新于 \(Format.relative($0))" } ?? " · 还没更新过"
            return (listIsUnreadOnly ? "\(unreadTotal) 篇未读" : "全部文章") + refresh
        case .starred:
            return "\(starredTotal) 篇星标"
        case .feed(let feedID):
            guard let feed = feeds.first(where: { $0.id == feedID }) else { return "订阅" }
            if let lastError = feed.lastError, !lastError.isEmpty {
                return "\(feed.unreadCount) 篇未读 · 上次更新失败"
            }
            return "\(feed.unreadCount) 篇未读 · 共 \(cloudFeedTotals[feedID] ?? database.countEntries(feedID: feedID)) 篇"
        }
    }

    var scopeFeed: Feed? {
        guard case .feed(let feedID) = listScope else { return nil }
        return feeds.first(where: { $0.id == feedID })
    }

    func setListTabBarVisible(_ visible: Bool) {
        guard listTabBarVisible != visible else { return }
        listTabBarVisible = visible
    }

    func setScope(_ scope: ListScope) {
        guard listScope != scope else { return }
        listScope = scope
        suppressSearch = true
        searchText = ""
        suppressSearch = false
        reloadList()
    }

    func clearSearch() {
        suppressSearch = true
        searchText = ""
        suppressSearch = false
        reloadList()
    }

    private func reloadList() {
        hiddenReadIDs.removeAll()
        if workspace != nil { reloadCloudList(); return }
        let page = database.entries(scope: listScope, unreadOnly: listIsUnreadOnly, search: searchText, cursor: nil, limit: pageSize, retainedReadIDs: retainedReadIDs)
        entries = page
        hasMore = page.count >= pageSize
        cursor = page.last.map { ($0.sortTime, $0.id) }
        updateTotals()
    }

    func loadMore() {
        guard allowsListPagination, listPageError == nil else { return }
        if workspace != nil && !cloudOffline {
            guard cloudPagination.hasLoadedPage, hasMore, !isLoadingMore, cloudListTask == nil else { return }
            // Reserve the request before yielding to the new Task. A recycled
            // loading row can appear more than once in the same run-loop turn.
            isLoadingMore = true
            cloudListTask = Task { await cloudPage(append: true) }
            return
        }
        guard hasMore, !isLoadingMore, let cursor else { return }
        isLoadingMore = true
        let page = database.entries(scope: listScope, unreadOnly: listIsUnreadOnly, search: searchText, cursor: cursor, limit: pageSize, retainedReadIDs: retainedReadIDs, feedIDs: workspace?.navigation.selectedFeeds ?? [])
        let existing = Set(entries.map(\.id))
        entries.append(contentsOf: page.filter { !existing.contains($0.id) && !hiddenReadIDs.contains($0.id) })
        hasMore = page.count >= pageSize
        self.cursor = page.last.map { ($0.sortTime, $0.id) } ?? cursor
        isLoadingMore = false
    }

    var allowsListPagination: Bool { !isRefreshing || preservingListDuringSync }

    func retryLoadMore() {
        listPageError = nil
        if workspace != nil { cloudOffline = false; hasMore = true }
        loadMore()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadList()
        }
    }

    private func reloadFeeds() {
        feeds = database.allFeeds().map { feed in
            var value = feed
            if let count = cloudFeedUnread[feed.id] { value.unreadCount = count }
            return value
        }
        updateTotals()
    }

    private func updateTotals() {
        if workspace != nil && cloudCountsTrusted { return }
        let totals = database.totals()
        unreadTotal = totals.unread
        starredTotal = totals.starred
    }

    // MARK: - 刷新

    func refreshIfNeeded() async {
        if workspace != nil {
            // Returning to the foreground may synchronize state, but must not
            // truncate loaded pages, reapply row geometry or replace the list.
            if let lastCloudOverviewAt, Date().timeIntervalSince(lastCloudOverviewAt) < Double(max(5, settings.refreshMinutes)) * 60 {
                if pendingCloudWrites > 0 { await flushCloudJournal() }
                return
            }
            await refreshCloud(fetch: false, preservingList: true)
            return
        }
        guard !feeds.isEmpty, settings.refreshMinutes > 0 else { return }
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < Double(settings.refreshMinutes) * 60 {
            return
        }
        await refreshAll(manual: false)
    }

    func refreshCurrent() async {
        if workspace != nil, case .feed(let id) = listScope { await refreshCloud(fetch: true, feedID: id) }
        else { await refreshAll() }
    }

    func refreshAll(manual: Bool = true) async {
        if workspace != nil { await refreshCloud(fetch: manual); return }
        guard !isRefreshing else { return }
        guard !feeds.isEmpty else {
            if manual { showBanner("先添加一个订阅", isError: false) }
            return
        }
        isRefreshing = true
        let result = await fetchAndApply(feeds)
        isRefreshing = false
        stampRefresh()
        reloadFeeds()
        if manual || entries.isEmpty {
            if manual { retainedReadIDs.removeAll() }
            reloadList()
        }

        if !result.failures.isEmpty {
            showBanner(result.failures.count == 1 ? result.failures[0] : "\(result.failures.count) 个订阅更新失败", isError: true)
        } else if result.added > 0 {
            showBanner("收到 \(result.added) 篇新文章", isError: false)
        } else if manual {
            showBanner("已经是最新了", isError: false)
        }
    }

    private func fetchAndApply(_ targets: [Feed]) async -> (added: Int, failures: [String]) {
        guard !targets.isEmpty else { return (0, []) }
        let outcomes = await withTaskGroup(of: FeedFetchOutcome.self, returning: [FeedFetchOutcome].self) { group in
            for feed in targets {
                group.addTask { await FeedService.shared.fetchOutcome(feed) }
            }
            var collected: [FeedFetchOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
        var byID: [String: Feed] = [:]
        for feed in targets { byID[feed.id] = feed }
        var added = 0
        var failures: [String] = []
        for outcome in outcomes {
            guard let feed = byID[outcome.feedID] else { continue }
            switch outcome.result {
            case .success(let fetched?):
                added += database.upsert(entries: fetched.entries, feedID: feed.id, fetchedAt: Date())
                database.updateFeedMeta(id: feed.id, title: fetched.title, siteURL: fetched.siteURL, iconURL: "")
                database.updateFetchState(id: feed.id, etag: fetched.etag, lastModified: fetched.lastModified, error: nil)
            case .success(nil):
                database.updateFetchState(id: feed.id, etag: "", lastModified: "", error: nil)
            case .failure(let error):
                let message = error.errorDescription ?? "更新失败"
                failures.append("\(feed.title)：\(message)")
                database.updateFetchState(id: feed.id, etag: "", lastModified: "", error: message)
            }
        }
        return (added, failures)
    }

    private func stampRefresh() {
        let now = Date()
        lastRefreshAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "weidu.lastRefreshAt")
    }

    // MARK: - 订阅管理

    func addFeed(_ raw: String, directTitle: String? = nil) async throws -> Feed {
        if let workspace {
            var payload: CloudValue = .object(["url": .string(raw), "fetch_now": .bool(true)])
            if let directTitle { payload["title"] = .string(directTitle) }
            let result = try await workspace.request("/api/weidu/feeds", method: "POST", payload: payload)
            await refreshCloud(fetch: false)
            guard let feed = database.feed(id: result["feed"]["id"].text) else { throw WeiduError.network("订阅已保存，请刷新后查看") }
            return feed
        }
        guard let normalized = Format.normalizedURL(raw) else { throw WeiduError.invalidURL }
        let feedURL: String
        let feedTitle: String
        if let directTitle {
            feedURL = normalized.absoluteString
            feedTitle = directTitle.isEmpty ? Format.host(feedURL) : directTitle
        } else {
            let options = try await FeedService.shared.discover(normalized.absoluteString)
            guard let first = options.first else { throw WeiduError.notAFeed }
            feedURL = first.url
            feedTitle = first.title
        }
        if isDuplicate(feedURL) { throw WeiduError.duplicateFeed }
        guard let inserted = database.insertFeed(url: feedURL, title: feedTitle) else {
            throw WeiduError.duplicateFeed
        }
        let target = database.feed(id: inserted.id) ?? inserted
        let result = await fetchAndApply([target])
        stampRefresh()
        reloadFeeds()
        reloadList()
        if result.failures.isEmpty {
            showBanner("已添加「\(feedTitle)」", isError: false)
        } else {
            showBanner("已添加「\(feedTitle)」，不过这次没抓到内容，稍后可下拉重试", isError: true)
        }
        return database.feed(id: inserted.id) ?? inserted
    }

    func isSubscribed(_ url: String) -> Bool {
        isDuplicate(url)
    }

    private func isDuplicate(_ url: String) -> Bool {
        let key = canonical(url)
        return feeds.contains { canonical($0.url) == key }
    }

    private func canonical(_ value: String) -> String {
        var text = value.lowercased()
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    func deleteFeed(_ feed: Feed) {
        if let workspace {
            Task { do {
                _ = try await workspace.request("/api/weidu/feeds/\(feed.id)", method: "DELETE")
                database.deleteFeed(id: feed.id)
                if listScope == .feed(feed.id) { listScope = .articles }
                await refreshCloud(fetch: false)
            } catch { showBanner(error.localizedDescription, isError: true) } }
            return
        }
        database.deleteFeed(id: feed.id)
        if listScope == .feed(feed.id) { listScope = .articles }
        reloadFeeds()
        reloadList()
        showBanner("已删除「\(feed.title)」", isError: false)
    }

    func openFeed(_ feed: Feed) {
        setScope(.feed(feed.id))
        selectedTab = .articles
    }

    func importOPML(_ data: Data) async -> (added: Int, skipped: Int) {
        if let workspace {
            let parsed = OPML.parse(data)
            do {
                var added = 0, skipped = 0, failures: [String] = []
                for start in stride(from: 0, to: parsed.count, by: 500) {
                    let chunk = Array(parsed.dropFirst(start).prefix(500))
                    let records = chunk.map { CloudValue.object(["url": .string($0.xmlURL), "title": .string($0.title)]) }
                    let result = try await workspace.request("/api/weidu/import", method: "POST", payload: .object(["feeds": .array(records), "fetch_now": .bool(true)]))
                    added += result["created"].int; skipped += result["skipped"].int
                    failures += result["failures"].array.map(\.text)
                }
                await refreshCloud(fetch: false)
                showBanner(failures.isEmpty ? "云端导入完成：新增 \(added) 个，跳过 \(skipped) 个" : "部分订阅未导入：" + failures.joined(separator: "；"), isError: !failures.isEmpty)
                return (added, skipped)
            } catch { showBanner("云端导入未完成：" + error.localizedDescription, isError: true); return (0, 0) }
        }
        let items = OPML.parse(data)
        var inserted: [Feed] = []
        var skipped = 0
        for item in items {
            guard let url = Format.normalizedURL(item.xmlURL) else {
                skipped += 1
                continue
            }
            if isDuplicate(url.absoluteString) {
                skipped += 1
                continue
            }
            if let feed = database.insertFeed(url: url.absoluteString, title: item.title) {
                inserted.append(feed)
            } else {
                skipped += 1
            }
        }
        reloadFeeds()
        reloadList()
        guard !inserted.isEmpty else {
            showBanner("没有导入新的订阅", isError: false)
            return (0, skipped)
        }
        isRefreshing = true
        let result = await fetchAndApply(inserted)
        isRefreshing = false
        stampRefresh()
        reloadFeeds()
        reloadList()
        var message = "导入 \(inserted.count) 个订阅"
        if !result.failures.isEmpty { message += "，\(result.failures.count) 个抓取失败" }
        showBanner(message, isError: !result.failures.isEmpty)
        return (inserted.count, skipped)
    }

    func opmlText() -> String {
        OPML.export(feeds: workspace == nil ? feeds : feeds.filter { ["http", "https"].contains(URL(string: $0.url)?.scheme?.lowercased() ?? "") })
    }

    // MARK: - 文章操作

    func open(_ entry: Entry) {
        readTrail.removeAll()
        openDetail(id: entry.id)
    }

    private func openDetail(id: String) {
        cloudOpenRevision = UUID()
        guard var detail = database.entry(id: id) else { return }
        if workspace != nil {
            var state: CloudValue = .object(["opened": .bool(true)])
            if settings.markReadOnOpen && !detail.isRead { state["read"] = .bool(true) }
            guard queueCloudState(id: id, state: state) else { return }
        }
        if settings.markReadOnOpen && !detail.isRead {
            database.markRead(id: detail.id, read: true)
            detail.isRead = true
            if listIsUnreadOnly { retainedReadIDs.insert(detail.id) }
        }
        if let index = entries.firstIndex(where: { $0.id == detail.id }) {
            entries[index].isRead = detail.isRead
            entries[index].opened = true
        } else if listIsUnreadOnly, retainedReadIDs.contains(detail.id) {
            entries.append(detail)
            entries.sort { $0.sortTime == $1.sortTime ? $0.id > $1.id : $0.sortTime > $1.sortTime }
        }
        database.markOpened(id: detail.id)
        readerSession = UUID()
        autoFulltextTask?.cancel()
        readerLoadingFulltext = fulltextRequests[detail.id] != nil
        readerLoadingBody = workspace != nil && Int(detail.id) != nil
        readerShowsFulltext = true
        let prepared = [readerNextPage, readerPreviousPage].compactMap { $0 }.first { $0.id == detail.id && !$0.html.isEmpty }
        readerEntry = detail
        readerHTML = prepared?.html ?? ReaderHTML.document(entry: detail, settings: settings)
        prepareReaderNeighbors()
        reloadFeeds()
        if workspace != nil {
            let session = readerSession
            Task { await loadCloudBody(id: id, session: session) }
            if let index = entries.firstIndex(where: { $0.id == id }), index >= entries.count - 3, hasMore { loadMore() }
        }
        if !isClearingCaches, fulltextRequests[detail.id] != nil || (database.feed(id: detail.feedID)?.autoFulltext == true && !detail.hasFulltext) {
            let session = readerSession
            autoFulltextTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self, self.readerSession == session else { return }
                await self.extractFulltext(automatic: true)
            }
        }
    }

    func openInAppBrowser(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        browserRequest = BrowserRequest(url: url)
    }

    func closeReader() {
        cloudOpenRevision = UUID()
        readerSession = UUID()
        autoFulltextTask?.cancel()
        readerLoadingFulltext = false
        readerLoadingBody = false
        readerPreparation?.cancel()
        readerNextPage = nil
        readerPreviousPage = nil
        readTrail.removeAll()
        readerEntry = nil
        readerHTML = ""
        updateTotals()
    }

    func clearReadFromList() {
        let hidden = Set(entries.filter(\.isRead).map(\.id))
        guard !hidden.isEmpty else { return }
        hiddenReadIDs.formUnion(hidden)
        retainedReadIDs.subtract(hidden)
        entries.removeAll { hidden.contains($0.id) }
        // This is only a view operation: keep the cursor, saved reading state,
        // current filters and unopened articles. No network reset is needed.
    }

    func handleTabDoubleTap(_ tab: AppTab) {
        if tab == .articles || tab == .starred { clearReadFromList() }
        scrollToTop.send(tab)
    }

    func nextUnread() {
        guard let current = readerEntry else { return }
        guard let next = nextUnreadEntry(after: current) else {
            showBanner("后面没有未读文章了", isError: false)
            return
        }
        readTrail.append(current.id)
        openDetail(id: next.id)
    }

    private func nextUnreadEntry(after current: Entry) -> Entry? {
        if workspace != nil {
            guard let index = entries.firstIndex(where: { $0.id == current.id }) else { return nil }
            return entries.dropFirst(index + 1).first(where: { !$0.isRead })
        }
        var position: (time: Double, id: String)? = (current.sortTime, current.id)
        while let cursor = position {
            let page = database.entries(scope: listScope, unreadOnly: true, search: searchText, cursor: cursor, limit: pageSize)
            if let next = page.first(where: { !$0.isRead }) { return next }
            guard page.count == pageSize, let last = page.last else { return nil }
            position = (last.sortTime, last.id)
        }
        return nil
    }

    func previousEntry() {
        guard let current = readerEntry else { return }
        if let id = readTrail.last, database.entry(id: id) != nil {
            readTrail.removeLast()
            openDetail(id: id)
            return
        }
        guard let index = entries.firstIndex(where: { $0.id == current.id }), index > 0 else {
            showBanner("前面没有文章了", isError: false)
            return
        }
        openDetail(id: entries[index - 1].id)
    }

    private func previousReaderEntry() -> Entry? {
        guard let current = readerEntry else { return nil }
        if let id = readTrail.last, let previous = database.entry(id: id) { return previous }
        guard let index = entries.firstIndex(where: { $0.id == current.id }), index > 0 else { return nil }
        return database.entry(id: entries[index - 1].id)
    }

    // Resolve neighbors once per article, never from a drag's per-frame callback.
    // Render HTML off the main thread so large feeds do not interrupt a gesture.
    private func prepareReaderNeighbors() {
        readerPreparation?.cancel()
        guard let current = readerEntry else { return }
        let next = nextUnreadEntry(after: current).flatMap { database.entry(id: $0.id) }
        let previous = previousReaderEntry()
        readerNextPage = next.map { ReaderPage(id: $0.id, url: $0.url, html: "") }
        readerPreviousPage = previous.map { ReaderPage(id: $0.id, url: $0.url, html: "") }
        let appearance = settings
        readerPreparation = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                [next, previous].map { entry -> ReaderPage? in
                    entry.map { ReaderPage(id: $0.id, url: $0.url, html: ReaderHTML.document(entry: $0, settings: appearance)) }
                }
            }.value
            guard !Task.isCancelled, let self, self.readerEntry?.id == current.id else { return }
            self.readerNextPage = rendered[0]
            self.readerPreviousPage = rendered[1]
        }
    }

    @discardableResult
    func turnReader(_ direction: ReaderTurnDirection, expectedID: String) -> Bool {
        let target = direction == .next ? readerEntry.flatMap { nextUnreadEntry(after: $0) } : previousReaderEntry()
        guard let target, target.id == expectedID else {
            showBanner(direction.unavailableHint, isError: false)
            prepareReaderNeighbors()
            return false
        }
        if direction == .next { nextUnread() } else { previousEntry() }
        return readerEntry?.id == expectedID
    }

    #if DEBUG
    private func seedFeatureRegression(media: Bool, count: Int = 18) {
        let url = "http://127.0.0.1:8765/rss"
        if let existing = database.feed(url: url) { database.deleteFeed(id: existing.id) }
        guard let feed = database.insertFeed(url: url, title: "功能回归订阅") else { return }
        let mediaBody = "<p>点击图片可全屏缩放，点击视频可播放。</p><img src='http://127.0.0.1:8765/image1.png' alt='媒体图片一'><img src='http://127.0.0.1:8765/image2.png' alt='媒体图片二'><video src='http://127.0.0.1:8765/video.mp4' poster='http://127.0.0.1:8765/image1.png'></video>"
        _ = database.upsert(entries: (1...(media ? 1 : count)).map { number in
            ParsedEntry(guid: "feature-\(number)", title: "功能测试第\(number)篇", url: "http://127.0.0.1:8765/article.html", author: "", summary: "订阅摘要第\(number)篇",
                        contentHTML: media ? mediaBody : "<p>订阅源原文第\(number)篇，原始内容仍然保留。</p>", imageURL: "", publishedAt: Date().addingTimeInterval(-Double(number * 60)))
        }, feedID: feed.id, fetchedAt: Date())
        settings.markReadOnOpen = false
        settings.autoReadOnScroll = ProcessInfo.processInfo.arguments.contains("--enable-auto-read")
        listScope = .feed(feed.id)
        selectedTab = .articles
        reloadFeeds()
        reloadList()
        if media, let first = entries.first { open(first) }
    }

    private func seedReaderRegression() {
        let url = "https://reader-regression.example.com/feed"
        if let existing = database.feed(url: url) { database.deleteFeed(id: existing.id) }
        guard let feed = database.insertFeed(url: url, title: "阅读交互测试") else { return }
        let items = (1...3).map { number in
            ParsedEntry(guid: "reader-test-\(number)", title: "跟手测试第\(number)篇", url: "https://reader-regression.example.com/\(number)", author: "",
                        summary: "阅读切换回归用例", contentHTML: (1...16).map { "<p>第\($0)段：让文字跟随手指移动。在安静的阅读里，留下一点思考的空间，继续读下一段。</p>" }.joined() + "<p>第\(number)篇文章结束</p>",
                        imageURL: "", publishedAt: Date().addingTimeInterval(-Double(number * 60)))
        }
        _ = database.upsert(entries: items, feedID: feed.id, fetchedAt: Date())
        listScope = .feed(feed.id)
        reloadFeeds()
        reloadList()
        if let first = entries.first { open(first) }
    }
    #endif

    func toggleStar(_ entry: Entry) {
        var current = entry
        if let reader = readerEntry, reader.id == entry.id { current = reader }
        let newValue = !current.isStarred
        if workspace != nil && !queueCloudState(id: current.id, state: .object(["starred": .bool(newValue)])) { return }
        database.markStarred(id: current.id, starred: newValue)
        if let index = entries.firstIndex(where: { $0.id == current.id }) {
            entries[index].isStarred = newValue
        }
        if readerEntry?.id == current.id {
            readerEntry?.isStarred = newValue
        }
        if listScope == .starred && !newValue {
            reloadList()
        }
        reloadFeeds()
    }

    func toggleRead(_ entry: Entry) {
        let read = !entry.isRead
        if workspace != nil && !queueCloudState(id: entry.id, state: .object(["read": .bool(read)])) { return }
        database.markRead(id: entry.id, read: read)
        if read && listIsUnreadOnly { retainedReadIDs.insert(entry.id) }
        if !read { retainedReadIDs.remove(entry.id) }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].isRead = read }
        if readerEntry?.id == entry.id {
            readerEntry?.isRead.toggle()
        }
        reloadFeeds()
    }

    func markReaderUnread() {
        guard let entry = readerEntry else { return }
        if workspace != nil && !queueCloudState(id: entry.id, state: .object(["read": .bool(false)])) { return }
        database.markRead(id: entry.id, read: false)
        retainedReadIDs.remove(entry.id)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].isRead = false }
        readerEntry?.isRead = false
        reloadFeeds()
        showBanner("已标为未读", isError: false)
    }

    func markAllRead() {
        if workspace != nil { Task { await markCloudScopeRead() }; return }
        if listIsUnreadOnly { retainedReadIDs.formUnion(entries.map(\.id)) }
        let count = database.markAllRead(scope: listScope)
        reloadFeeds()
        reloadList()
        showBanner(count > 0 ? "已将 \(count) 篇标为已读" : "没有需要处理的文章", isError: false)
    }

    var readerCanSwitchSource: Bool { readerHTML.contains("weidu-reader://source") }

    func toggleReaderSource() {
        guard readerCanSwitchSource, let entry = readerEntry else { return }
        readerShowsFulltext.toggle()
        readerHTML = ReaderHTML.document(entry: entry, settings: settings, showFulltext: readerShowsFulltext)
    }

    func setAutoFulltext(_ feed: Feed, enabled: Bool) {
        if let workspace {
            Task { do { _ = try await workspace.request("/api/weidu/feeds/\(feed.id)", method: "PATCH", payload: .object(["auto_fulltext": .bool(enabled)])); await refreshCloud(fetch: false) }
                catch { showBanner(error.localizedDescription, isError: true) } }
            return
        }
        database.setAutoFulltext(feedID: feed.id, enabled: enabled)
        reloadFeeds()
    }

    func markScrolledEntriesRead(_ ids: Set<String>) {
        guard settings.autoReadOnScroll, readerEntry == nil, selectedTab == .articles || selectedTab == .starred else { return }
        let passed = Set(entries.filter { ids.contains($0.id) && !$0.isRead }.map(\.id))
        guard !passed.isEmpty else { return }
        if workspace != nil {
            guard queueCloudReads(passed) else { return }
        }
        database.markRead(ids: passed)
        if listIsUnreadOnly { retainedReadIDs.formUnion(passed) }
        // Publish the batch once. Re-querying every feed's counts or publishing
        // each changed array element interrupts the list while it is scrolling.
        var updatedEntries = entries
        var counts: [String: Int] = [:]
        for index in updatedEntries.indices where passed.contains(updatedEntries[index].id) {
            counts[updatedEntries[index].feedID, default: 0] += 1
            updatedEntries[index].isRead = true
        }
        entries = updatedEntries
        var updatedFeeds = feeds
        for index in updatedFeeds.indices {
            if let count = counts[updatedFeeds[index].id] {
                updatedFeeds[index].unreadCount = max(0, updatedFeeds[index].unreadCount - count)
            }
        }
        feeds = updatedFeeds
        if workspace == nil { unreadTotal = max(0, unreadTotal - passed.count) }
        // Keep rows and the pagination cursor in place, as in PWA.
    }

    var canSweepListRead: Bool {
        settings.autoReadOnScroll && !hasMore && !isLoadingMore && !isRefreshing && readerEntry == nil
            && (selectedTab == .articles || selectedTab == .starred) && listSnapshot.unreadCount > 0
    }

    func markRemainingListRead() {
        guard canSweepListRead else { return }
        let remaining = Set(entries.filter { !$0.isRead }.map(\.id))
        // Use the loaded, filtered list; markAllRead would also affect rows
        // outside a search, and reloading would remove retained read rows.
        markScrolledEntriesRead(remaining)
        showBanner("已将 \(remaining.count) 篇标为已读", isError: false)
    }

    func extractFulltext(automatic: Bool = false, force: Bool = false) async {
        if workspace != nil { await cloudFulltext(); return }
        guard let current = readerEntry, !current.url.isEmpty, !isClearingCaches else { return }
        let session = readerSession
        let generation = cacheGeneration
        if !force, fulltextRequests[current.id] == nil, let cached = database.entry(id: current.id), cached.hasFulltext {
            readerLoadingFulltext = false
            readerEntry = cached
            readerShowsFulltext = true
            readerHTML = ReaderHTML.document(entry: cached, settings: settings)
            if !automatic { showBanner("正文已缓存在本机，直接阅读", isError: false) }
            return
        }
        let request: (id: UUID, task: Task<String, Error>)
        if let existing = fulltextRequests[current.id] { request = existing }
        else {
            let fetch = fulltextFetcher
            request = (UUID(), Task { try await fetch(current.url, current.title) })
            fulltextRequests[current.id] = request
        }
        readerLoadingFulltext = true
        defer {
            if fulltextRequests[current.id]?.id == request.id { fulltextRequests.removeValue(forKey: current.id) }
            if readerSession == session { readerLoadingFulltext = false }
        }
        do {
            let html = try await request.task.value
            guard !request.task.isCancelled, cacheGeneration == generation else { return }
            database.setFulltext(id: current.id, html: html)
            guard readerSession == session, let refreshed = database.entry(id: current.id) else { return }
            readerEntry = refreshed
            readerShowsFulltext = true
            readerHTML = ReaderHTML.document(entry: refreshed, settings: settings)
            prepareReaderNeighbors()
            if !automatic { showBanner("正文已抓到并缓存在本机", isError: false) }
        } catch {
            guard readerSession == session, cacheGeneration == generation, !request.task.isCancelled else { return }
            let message = (error as? WeiduError)?.errorDescription ?? error.localizedDescription
            showBanner((automatic ? "自动抓取失败，已保留现有内容；可手动重试或打开原文：" : "抓正文失败：") + message, isError: true)
        }
    }

    func refreshCacheUsage() async {
        articleCacheUsage = database.fulltextCacheUsage()
        imageCacheUsage = await ImageCache.shared.usage()
    }

    func clearCaches(_ kind: CacheKind = .all, automatic: Bool = false, now: Date = Date()) async {
        guard !isClearingCaches else { return }
        isClearingCaches = true
        defer { isClearingCaches = false }
        do {
            if kind != .images {
                cacheGeneration += 1
                autoFulltextTask?.cancel()
                fulltextRequests.values.forEach { $0.task.cancel() }
                fulltextRequests.removeAll()
                readerLoadingFulltext = false
                readerLoadingBody = false
                try database.clearFulltextCache()
                readerPreparation?.cancel()
                readerNextPage = nil
                readerPreviousPage = nil
                if let id = readerEntry?.id, let refreshed = database.entry(id: id) {
                    readerEntry = refreshed
                    readerShowsFulltext = false
                    readerHTML = ReaderHTML.document(entry: refreshed, settings: settings, showFulltext: false)
                    prepareReaderNeighbors()
                }
                let file = database.fileURL
                await Task.detached(priority: .utility) { Database(url: file).compact() }.value
            }
            if kind != .articles {
                try await ImageCache.shared.clear()
                URLCache.shared.removeAllCachedResponses()
            }
            if kind == .all {
                lastCacheCleanupAt = now
                cacheScheduleStart = now
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "weidu.lastCacheCleanupAt")
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "weidu.cacheScheduleStart")
            }
            await refreshCacheUsage()
            if !automatic { showBanner("缓存已清理", isError: false) }
        } catch {
            if !automatic { showBanner("清理未完成：\(error.localizedDescription)", isError: true) }
            await refreshCacheUsage()
        }
    }

    func maintenanceIfNeeded(now: Date = Date()) async {
        guard !maintaining else { return }
        maintaining = true
        defer { maintaining = false }
        if CachePolicy.isDue(days: settings.cacheCleanupDays, since: cacheScheduleStart, now: now) {
            await clearCaches(.all, automatic: true, now: now)
        }
    }

    // MARK: - 提示

    func showBanner(_ text: String, isError: Bool) {
        let value = Banner(text: text, isError: isError)
        banner = value
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.banner?.id == value.id {
                self?.banner = nil
            }
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }
}

// Keep the original local reader intact. Cloud metadata uses its own database,
// and state changes are journaled before they become visible to the user.
extension Store {
    private var cloudFeedIDs: [String] { workspace?.navigation.selectedFeeds ?? [] }

    private func cloudQuery(limit: Int, offset: Int) -> String {
        var query = [URLQueryItem(name: "view", value: listScope == .starred ? "starred" : (listIsUnreadOnly ? "unread" : "all")),
                     URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if case .feed(let id) = listScope { query.append(URLQueryItem(name: "feed_id", value: id)) }
        else if !cloudFeedIDs.isEmpty { query.append(URLQueryItem(name: "feed_ids", value: cloudFeedIDs.joined(separator: ","))) }
        if !searchText.isEmpty { query.append(URLQueryItem(name: "q", value: searchText)) }
        var components = URLComponents(); components.queryItems = query
        return "/api/weidu/entries?" + (components.percentEncodedQuery ?? "")
    }

    private func reloadCloudList(loadRemote: Bool = true) {
        hiddenReadIDs.removeAll()
        cloudListTask?.cancel(); cloudListTask = nil
        cloudListRevision = UUID(); cloudPagination = CloudListPagination()
        listPageError = nil; isLoadingMore = false
        let cached = database.entries(scope: listScope, unreadOnly: listIsUnreadOnly, search: searchText,
            cursor: nil, limit: pageSize, retainedReadIDs: retainedReadIDs, feedIDs: cloudFeedIDs)
        entries = cached; cursor = cached.last.map { ($0.sortTime, $0.id) }; hasMore = cached.count >= pageSize
        if loadRemote { cloudListTask = Task { await cloudPage(append: false) } }
    }

    private func cloudPage(append: Bool) async {
        // A task cancelled before it starts must not claim the replacement
        // list's revision or clear that list's loading reservation in defer.
        guard let workspace, !Task.isCancelled else { return }
        let revision = cloudListRevision
        if !isLoadingMore { isLoadingMore = true }
        defer {
            if cloudListRevision == revision { isLoadingMore = false; cloudListTask = nil }
        }
        do {
            // Fetch only the next page, as PWA does. Confirmed read/unstar ACKs
            // adjust the offset so those removals do not skip unseen articles.
            let offset = append ? cloudPagination.offset(unreadOnly: listIsUnreadOnly, starredOnly: listScope == .starred) : 0
            var ids: [String] = []
            let stateVersion = cloudStateVersion
            let result = try await workspace.request(cloudQuery(limit: pageSize, offset: offset))
            try Task.checkCancellation(); guard cloudListRevision == revision else { return }
            let rows = result["items"].array
            // Short transactions avoid a disk commit per article. Yield
            // between chunks so a page cannot occupy a frame for its entire
            // merge. No transaction survives an await.
            for start in stride(from: 0, to: rows.count, by: 16) {
                try Task.checkCancellation(); guard cloudListRevision == revision else { return }
                let chunk = Array(rows.dropFirst(start).prefix(16))
                let pending = Dictionary(chunk.compactMap { item -> (String, CloudValue)? in
                    let id = Database.cloudID(item)
                    return cloudJournal?.state(id).map { (id, $0) }
                }, uniquingKeysWith: { _, new in new })
                ids.append(contentsOf: try database.mergeCloudList(chunk, pending: pending, preserveState: stateVersion != cloudStateVersion))
                await Task.yield()
            }
            try Task.checkCancellation(); guard cloudListRevision == revision else { return }
            cloudPagination.record(rows, requestRevision: stateVersion)
            let metadata = Dictionary(uniqueKeysWithValues: database.listEntries(ids: ids).map { ($0.id, $0) })
            var seen = append ? Set(entries.map(\.id)) : Set<String>()
            let next = ids.filter { seen.insert($0).inserted && !hiddenReadIDs.contains($0) }.compactMap { metadata[$0] }
            // Preserve existing row order and IDs. Appending cannot move the
            // viewport, including when new server articles overlap this page.
            let updated = append ? entries + next : next
            if entries != updated { entries = updated }
            hasMore = result["has_more"].flag && !rows.isEmpty; cloudOffline = false; listPageError = nil
            cursor = entries.last.map { ($0.sortTime, $0.id) }; prepareReaderNeighbors()
        } catch is CancellationError { }
        catch {
            guard cloudListRevision == revision else { return }
            cloudOffline = true
            if append { listPageError = error.localizedDescription }
            else { showBanner("云端暂不可用，正在显示本机缓存：" + error.localizedDescription, isError: true) }
        }
    }

    func refreshCloud(fetch: Bool, feedID: String? = nil, preservingList: Bool = false) async {
        guard let workspace, !isRefreshing else { return }
        preservingListDuringSync = preservingList && cloudPagination.hasLoadedPage
        isRefreshing = true
        defer { isRefreshing = false; preservingListDuringSync = false }
        await flushCloudJournal()
        do {
            var resultMessage: String?, failed = false
            if fetch, let feedID {
                var kind = cloudFeedKinds[feedID]
                if kind == nil {
                    let rows = try await workspace.request("/api/weidu/feeds")["items"].array
                    guard let feed = rows.first(where: { $0["id"].text == feedID }) else { throw WeiduError.network("订阅已删除，请刷新列表") }
                    kind = feed["kind"].text
                }
                if kind != "saved" {
                    let path = kind == "watch" ? "/api/weidu/watch/\(feedID)/check" : "/api/weidu/feeds/\(feedID)/refresh"
                    let response = try await workspace.request(path, method: "POST")
                    let error = response["result"]["error"].text
                    failed = !error.isEmpty
                    resultMessage = failed ? "更新失败：" + error : kind == "watch" ? "已检查当前网页监测" : "当前订阅新增 \(response["result"]["added"].int) 篇文章"
                }
            } else if fetch {
                let response = try await workspace.request("/api/weidu/refresh", method: "POST")
                failed = response["failed"].int > 0
                resultMessage = "新增 \(response["added"].int) 篇文章" + (failed ? "，\(response["failed"].int) 个源失败：" + response["failures"].array.map(\.text).joined(separator: "；") : "")
            }
            let version = cloudStateVersion
            let result = try await workspace.request("/api/weidu/overview")
            try Task.checkCancellation()
            try database.mergeCloudFeeds(result["feeds"].array)
            cloudFeedTotals = Dictionary(uniqueKeysWithValues: result["feeds"].array.map { ($0["id"].text, $0["total"].int) })
            cloudFeedKinds = Dictionary(uniqueKeysWithValues: result["feeds"].array.map { ($0["id"].text, $0["kind"].text) })
            var scopeRemoved = false
            if case .feed(let id) = listScope, database.feed(id: id) == nil { listScope = .articles; scopeRemoved = true }
            let available = Set(result["feeds"].array.map { $0["id"].text })
            let selection = workspace.navigation.selectedFeeds.filter { available.contains($0) }
            if selection != workspace.navigation.selectedFeeds { workspace.navigation.selectFeeds(selection.compactMap(Int.init)) }
            if let current = readerEntry, database.entry(id: current.id) == nil { closeReader() }
            if version == cloudStateVersion && (cloudJournal?.operations.isEmpty ?? true) {
                cloudFeedUnread = Dictionary(uniqueKeysWithValues: result["feeds"].array.map { ($0["id"].text, $0["unread"].int) })
                unreadTotal = result["counts"]["unread"].int; starredTotal = result["counts"]["starred"].int
                cloudCountsTrusted = true
            }
            let keepList = preservingList && cloudPagination.hasLoadedPage && !scopeRemoved
            if version == cloudStateVersion, !keepList { applyCloudPreferences(result["prefs"]) }
            reloadFeeds(); lastRefreshAt = Date(); cloudOffline = false
            lastCloudOverviewAt = Date()
            if !keepList { reloadList() }
            pendingCloudWrites = cloudJournal?.operations.count ?? 0
            if let resultMessage { showBanner(resultMessage, isError: failed) }
        } catch is CancellationError { }
        catch {
            if !preservingList || !cloudPagination.hasLoadedPage { cloudOffline = true }
            showBanner("同步未完成，已保留本机内容：" + error.localizedDescription, isError: true)
        }
    }

    @discardableResult
    private func queueCloudState(id: String, state: CloudValue) -> Bool {
        guard let cloudJournal, let serverID = Int(id), serverID > 0 else { return false }
        do {
            try cloudJournal.enqueue(id: "entry:\(id)", path: "/api/weidu/entries/\(serverID)/state", body: state)
            if let entry = database.listEntry(id: id) {
                if state["read"] != .null {
                    let read = state["read"].flag
                    if entry.isRead != read {
                        let delta = read ? -1 : 1
                        unreadTotal = max(0, unreadTotal + delta)
                        cloudFeedUnread[entry.feedID] = max(0, (cloudFeedUnread[entry.feedID] ?? feeds.first { $0.id == entry.feedID }?.unreadCount ?? 0) + delta)
                    }
                    database.markRead(id: id, read: read)
                }
                if state["starred"] != .null {
                    let starred = state["starred"].flag
                    if entry.isStarred != starred { starredTotal = max(0, starredTotal + (starred ? 1 : -1)) }
                    database.markStarred(id: id, starred: starred)
                }
            }
            cloudStateVersion += 1; pendingCloudWrites = cloudJournal.operations.count
            scheduleCloudFlush()
            return true
        } catch { showBanner("无法保存离线修改：" + error.localizedDescription, isError: true); return false }
    }

    private func queueCloudReads(_ ids: Set<String>) -> Bool {
        guard let cloudJournal else { return false }
        let operations = ids.sorted().compactMap { id -> CloudOperation? in
            guard let serverID = Int(id), serverID > 0 else { return nil }
            return CloudOperation(id: "entry:\(id)", revision: UUID(), path: "/api/weidu/entries/\(serverID)/state", body: .object(["read": .bool(true)]))
        }
        guard operations.count == ids.count else { return false }
        do {
            // Persist the entire batch before changing local state. One atomic
            // journal write replaces N rewrites and cannot leave half a batch.
            try cloudJournal.enqueue(operations)
            for entry in entries where ids.contains(entry.id) && !entry.isRead {
                cloudFeedUnread[entry.feedID] = max(0, (cloudFeedUnread[entry.feedID] ?? feeds.first { $0.id == entry.feedID }?.unreadCount ?? 0) - 1)
            }
            unreadTotal = max(0, unreadTotal - ids.count)
            cloudStateVersion += 1; pendingCloudWrites = cloudJournal.operations.count
            scheduleCloudFlush()
            return true
        } catch { showBanner("无法保存离线修改：" + error.localizedDescription, isError: true); return false }
    }

    private func scheduleCloudFlush() {
        cloudFlushTask?.cancel()
        cloudFlushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self else { return }
            self.cloudFlushTask = nil
            await self.flushCloudJournal()
        }
    }

    private func flushCloudJournal() async {
        guard let workspace, let cloudJournal, !cloudFlushing else { return }
        if let failure = cloudJournal.loadFailure { showBanner(failure, isError: true); return }
        cloudFlushing = true; defer { cloudFlushing = false; pendingCloudWrites = cloudJournal.operations.count }
        do {
            while !cloudJournal.operations.isEmpty {
                try Task.checkCancellation()
                let snapshot = cloudJournal.operations
                for read in [true, false] {
                    let grouped = snapshot.filter { $0.id.hasPrefix("entry:") && Set($0.body.object.keys) == ["read"] && $0.body["read"].flag == read }
                    for start in stride(from: 0, to: grouped.count, by: 5000) {
                        let batch = Array(grouped.dropFirst(start).prefix(5000))
                        let ids = batch.compactMap { Int($0.id.dropFirst(6)) }.map { CloudValue.number(Double($0)) }
                        _ = try await workspace.request("/api/weidu/entries/state", method: "POST", payload: .object(["ids": .array(ids), "read": .bool(read)]))
                        try cloudJournal.acknowledge(batch)
                        cloudStateVersion += 1
                        for op in batch { cloudPagination.acknowledge(id: String(op.id.dropFirst(6)), body: op.body, revision: cloudStateVersion) }
                    }
                }
                for op in snapshot where !(op.id.hasPrefix("entry:") && Set(op.body.object.keys) == ["read"]) {
                    var deleted = false
                    do { _ = try await workspace.request(op.path, method: op.id == "prefs" ? "PATCH" : "POST", payload: op.body) }
                    catch let error as WeiduWorkspaceFailure where error.status == 404 && op.id.hasPrefix("entry:") { deleted = true }
                    try cloudJournal.acknowledge(op)
                    cloudStateVersion += 1
                    if op.id.hasPrefix("entry:") { cloudPagination.acknowledge(id: String(op.id.dropFirst(6)), body: op.body, revision: cloudStateVersion, deleted: deleted) }
                }
            }
        } catch { showBanner("离线修改已保留，稍后继续同步：" + error.localizedDescription, isError: true) }
    }

    private func cloudPreferenceValues(_ value: AppSettings) -> [String: CloudValue] {
        var values: [String: CloudValue] = ["font": .string(value.readingFont.rawValue),
            "font_size": .string([16: "sm", 18: "md", 20: "lg", 23: "xl"][value.readingSize] ?? "md"),
            "density": .string(value.density == .normal ? "comfortable" : value.density.rawValue),
            "list_view": .string(value.listView.rawValue), "keep_days": .number(Double(value.keepDays)),
            "images_in_list": .bool(value.imagesInList), "mark_read_on_open": .bool(value.markReadOnOpen),
            "auto_read_on_scroll": .bool(value.autoReadOnScroll)]
        if value.refreshMinutes >= 5 { values["refresh_minutes"] = .number(Double(value.refreshMinutes)) }
        return values
    }

    private func queueCloudPreferences(previous: AppSettings) {
        guard let cloudJournal else { return }
        let old = cloudPreferenceValues(previous)
        let delta = cloudPreferenceValues(settings).filter { old[$0.key] != $0.value }
        guard !delta.isEmpty else { return }
        do {
            try cloudJournal.enqueue(id: "prefs", path: "/api/weidu/prefs", body: .object(delta))
            pendingCloudWrites = cloudJournal.operations.count
            Task { await flushCloudJournal() }
        } catch { showBanner("阅读偏好尚未同步：" + error.localizedDescription, isError: true) }
    }

    private func applyCloudPreferences(_ remote: CloudValue) {
        var p = remote.object
        p.merge(cloudJournal?.operations.first { $0.id == "prefs" }?.body.object ?? [:]) { _, local in local }
        cloudApplyingPrefs = true; defer { cloudApplyingPrefs = false }
        var s = settings
        if let font = p["font"], let v = ReadingFont(rawValue: font.text) { s.readingFont = v }
        if let size = p["font_size"], let v = ["sm": 16, "md": 18, "lg": 20, "xl": 23][size.text] { s.readingSize = v }
        if let density = p["density"] { s.density = density.text == "comfortable" ? .normal : (ListDensity(rawValue: density.text) ?? s.density) }
        if let view = p["list_view"], let v = UnreadFilter(rawValue: view.text) { s.listView = v }
        if let v = p["keep_days"] { s.keepDays = v.int }
        if let v = p["refresh_minutes"] { s.refreshMinutes = v.int }
        if let v = p["images_in_list"] { s.imagesInList = v.flag }
        if let v = p["mark_read_on_open"] { s.markReadOnOpen = v.flag }
        if let v = p["auto_read_on_scroll"] { s.autoReadOnScroll = v.flag }
        if s != settings { settings = s }
    }

    private func loadCloudBody(id: String, session: UUID) async {
        guard let workspace, let serverID = Int(id), readerSession == session else { return }
        let generation = cacheGeneration, contentVersion = cloudContentVersion
        let stateVersion = cloudStateVersion
        defer { if readerSession == session { readerLoadingBody = false } }
        do {
            let result = try await workspace.request("/api/weidu/entries/\(serverID)")
            try Task.checkCancellation()
            guard generation == cacheGeneration, contentVersion == cloudContentVersion else { return }
            _ = try database.mergeCloudEntry(result["entry"], pending: cloudJournal?.state(id), preserveState: stateVersion != cloudStateVersion)
            guard readerSession == session, let entry = database.entry(id: id) else { return }
            readerEntry = entry; readerHTML = ReaderHTML.document(entry: entry, settings: settings, showFulltext: readerShowsFulltext)
            prepareReaderNeighbors()
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { if readerSession == session, generation == cacheGeneration { showBanner("正文同步未完成，保留已缓存内容：" + error.localizedDescription, isError: true) } }
    }

    private func cloudFulltext() async {
        guard let workspace, let current = readerEntry, let id = Int(current.id), !readerLoadingFulltext else { return }
        cloudContentVersion += 1
        // The older body GET is superseded by this full-text request, including its loading indicator.
        readerLoadingBody = false
        let session = readerSession, generation = cacheGeneration
        let stateVersion = cloudStateVersion
        readerLoadingFulltext = true
        defer { if readerSession == session { readerLoadingFulltext = false } }
        do {
            let result = try await workspace.request("/api/weidu/entries/\(id)/fulltext", method: "POST")
            guard generation == cacheGeneration else { return }
            _ = try database.mergeCloudEntry(result["entry"], pending: cloudJournal?.state(current.id), preserveState: stateVersion != cloudStateVersion)
            guard readerSession == session, let entry = database.entry(id: current.id) else { return }
            readerEntry = entry; readerShowsFulltext = true
            readerHTML = ReaderHTML.document(entry: entry, settings: settings); prepareReaderNeighbors()
        } catch { if readerSession == session { showBanner("抓正文失败：" + error.localizedDescription, isError: true) } }
    }

    func openCloudArticle(_ id: String) async {
        guard let workspace, let number = Int(id) else { return }
        let stateVersion = cloudStateVersion
        let revision = UUID(); cloudOpenRevision = revision
        do {
            let result = try await workspace.request("/api/weidu/entries/\(number)")
            try Task.checkCancellation(); guard revision == cloudOpenRevision else { return }
            let entryID = try database.mergeCloudEntry(result["entry"], pending: cloudJournal?.state(Database.cloudID(result["entry"])), preserveState: stateVersion != cloudStateVersion)
            openDetail(id: entryID)
        } catch { if revision == cloudOpenRevision, !Task.isCancelled { showBanner(error.localizedDescription, isError: true) } }
    }

    private func markCloudScopeRead() async {
        guard let workspace, !isRefreshing else { return }
        isRefreshing = true
        do {
            await flushCloudJournal()
            guard cloudJournal?.operations.isEmpty == true else { throw WeiduError.network("请先完成离线修改同步") }
            var ids: [CloudValue] = [], offset = 0, more = true
            while more {
                let result = try await workspace.request(cloudQuery(limit: 500, offset: offset))
                let rows = result["items"].array; ids += rows.map { $0["id"] }
                offset += rows.count; more = result["has_more"].flag && !rows.isEmpty
            }
            for start in stride(from: 0, to: ids.count, by: 5000) {
                _ = try await workspace.request("/api/weidu/entries/state", method: "POST", payload: .object(["ids": .array(Array(ids.dropFirst(start).prefix(5000))), "read": .bool(true)]))
            }
            database.markRead(ids: Set(ids.map { String(format: "%020lld", Int64($0.int)) }))
            retainedReadIDs.formUnion(entries.map(\.id))
            showBanner("已将当前筛选的 \(ids.count) 篇文章标为已读", isError: false)
        } catch { showBanner("批量标记未完成，请联网后刷新核对：" + error.localizedDescription, isError: true) }
        isRefreshing = false; await refreshCloud(fetch: false)
    }
}
