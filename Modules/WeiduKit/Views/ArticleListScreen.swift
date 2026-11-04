import SwiftUI
import UIKit
import Combine

struct ArticleListScreen: View {
    let scope: ListScope

    @EnvironmentObject private var store: Store
    @Environment(\.hostAppActions) private var appActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.readerBottomClearance) private var bottomClearance
    @State private var searchActive = false
    @State private var headerVisible = true
    @State private var confirmMarkAll = false
    // AppHeader starts at 44pt controls + 8pt top + 12pt bottom. Replace with its measured height below.
    @State private var headerHeight: CGFloat = 64
    @State private var sweepReady = false
    @StateObject private var headerScroll = ListHeaderGestureObserver()
    @FocusState private var searchFocused: Bool

    private var isStarredScope: Bool { scope == .starred }
    private var isActiveList: Bool { store.selectedTab == (isStarredScope ? .starred : .articles) }

    var body: some View {
        ZStack(alignment: .top) {
            list
            VStack(spacing: 0) {
                header
                if searchActive { searchRow }
            }
            .background(GlassBar())
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { updateHeaderHeight(geometry.size.height) }
                    .onChange(of: geometry.size.height) { _, height in updateHeaderHeight(height) }
            })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("article-list-header")
            .accessibilityValue(headerScroll.diagnostic)
            .opacity(headerVisible || searchActive ? 1 : 0)
            .offset(y: headerVisible || searchActive || reduceMotion ? 0 : -headerHeight)
            .allowsHitTesting(headerVisible || searchActive)
            .accessibilityHidden(!headerVisible && !searchActive)
        }
        .overlay(alignment: .top) {
            // Keep scrolling rows behind an opaque status bar even when the toolbar is removed.
            Theme.background.frame(height: 1)
                .background(Theme.background, ignoresSafeAreaEdges: .top)
                .allowsHitTesting(false)
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            if isActiveList { headerVisible = true; store.setListTabBarVisible(true) }
            headerScroll.resume()
            headerScroll.setAutoReadEnabled(store.settings.autoReadOnScroll)
            headerScroll.setSweepEnabled(store.canSweepListRead)
            updatePagination()
            if isStarredScope {
                store.setScope(.starred)
            } else if case .starred = store.listScope {
                store.setScope(.articles)
            }
        }
        .onDisappear { headerScroll.suspend() }
        .onReceive(headerScroll.passedEntries) { store.markScrolledEntriesRead($0) }
        .onReceive(headerScroll.sweepRead) { store.markRemainingListRead() }
        .onReceive(headerScroll.sweepReadiness) { sweepReady = $0 }
        .onReceive(headerScroll.nextPage) { if isActiveList { store.loadMore() } }
        .onReceive(store.scrollToTop) { tab in
            guard tab == (isStarredScope ? .starred : .articles), isActiveList else { return }
            headerVisible = true; store.setListTabBarVisible(true)
            headerScroll.scrollToTop(animated: !reduceMotion)
        }
        .onChange(of: store.hasMore) { _, _ in updatePagination() }
        .onChange(of: store.isLoadingMore) { _, _ in updatePagination() }
        .onChange(of: store.isRefreshing) { _, _ in updatePagination() }
        .onChange(of: store.listPageError) { _, _ in updatePagination() }
        .onChange(of: store.selectedTab) { _, _ in updatePagination() }
        .onChange(of: store.canSweepListRead) { _, enabled in headerScroll.setSweepEnabled(enabled) }
        .onChange(of: store.listSnapshot.ids) { _, _ in
            headerScroll.cancelSweep(); headerScroll.listChanged()
        }
        .onChange(of: store.settings.autoReadOnScroll) { _, enabled in headerScroll.setAutoReadEnabled(enabled) }
        .onChange(of: store.readerEntry?.id) { _, id in
            if id == nil, isActiveList {
                headerVisible = true; store.setListTabBarVisible(true); headerScroll.resume()
            } else { headerScroll.suspend() }
            updatePagination()
        }
        .onChange(of: store.searchText) { _, _ in headerScroll.resetReadTracking() }
        .onChange(of: searchActive) { _, active in
            if active, isActiveList { store.setListTabBarVisible(true) }
        }
        .onReceive(headerScroll.visibility) { show in
            guard isActiveList, store.readerEntry == nil, !searchActive else { return }
            store.setListTabBarVisible(show)
            guard show != headerVisible else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { headerVisible = show }
        }
        .onChange(of: store.listScope) { _, _ in
            headerScroll.resetReadTracking()
            headerScroll.scrollToTop(animated: false)
            searchActive = false
            searchFocused = false
            headerVisible = true
            if isActiveList { store.setListTabBarVisible(true) }
        }
        .onChange(of: store.entries.isEmpty) { _, empty in
            if empty {
                headerVisible = true
                if isActiveList { store.setListTabBarVisible(true) }
            }
        }
        .confirmationDialog("将当前范围内的文章全部标为已读？", isPresented: $confirmMarkAll, titleVisibility: .visible) {
            Button("全部标为已读") { store.markAllRead() }
            Button("取消", role: .cancel) {}
        }
    }

    private func updateHeaderHeight(_ height: CGFloat) {
        guard height > 0, abs(headerHeight - height) > 0.5 else { return }
        headerScroll.preserveTopDuringHeaderRelayout(to: height)
        headerHeight = height
    }

    private func updatePagination() {
        headerScroll.setPaginationEnabled(isActiveList && store.hasMore && !store.isLoadingMore && store.allowsListPagination && store.listPageError == nil && store.readerEntry == nil)
    }

    private var header: some View {
        AppHeader(
            title: store.scopeTitle,
            subtitle: store.scopeSubtitle,
            back: backAction
        ) {
            HStack(spacing: 2) {
                HeaderIconButton(systemName: "arrow.clockwise", spinning: store.isRefreshing) {
                    Task { await store.refreshCurrent() }
                }
                HeaderIconButton(systemName: "magnifyingglass") {
                    headerScroll.captureTopBeforeHeaderChange()
                    headerVisible = true
                    searchActive = true
                    DispatchQueue.main.async { searchFocused = true }
                }
                Menu {
                    appActions()
                    if !isStarredScope {
                        Picker("显示", selection: $store.settings.listView) {
                            ForEach(UnreadFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        Divider()
                    }
                    Button {
                        Task { await store.refreshCurrent() }
                    } label: { Label("更新文章", systemImage: "arrow.clockwise") }
                    if store.listIsUnreadOnly {
                        Button { store.clearReadFromList() } label: {
                            Label("隐藏已读文章", systemImage: "checkmark.circle")
                        }
                    }
                    Divider()
                    Button { confirmMarkAll = true } label: {
                        Label("全部标为已读", systemImage: "checkmark.circle.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("文章操作")
            }
        }
    }

    private var backAction: (() -> Void)? {
        if case .feed = store.listScope {
            return { store.setScope(.articles) }
        }
        return nil
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                TextField("搜索标题或摘要", text: $store.searchText)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !store.searchText.isEmpty {
                    Button {
                        store.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Button("取消") {
                headerScroll.captureTopBeforeHeaderChange()
                searchActive = false
                searchFocused = false
                store.clearSearch()
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    private var list: some View {
        List {
            // This is content padding, not a changing viewport inset. Hiding the overlay never resizes the list.
            Color.clear.frame(height: headerHeight)
                .background(ListScrollAnchor(observer: headerScroll, headerHeight: headerHeight))
                .id("header-clearance-\(headerHeight)")
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)
                .accessibilityHidden(true)
            if store.entries.isEmpty {
                emptyView
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
            } else {
                // Keep ForEach directly in List so every article remains its
                // own reusable cell. Equatable wraps only the single row body.
                ForEach(store.listSnapshot.groups) { group in
                    if store.settings.listStyle == .card {
                    Text(group.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("article-day-header-\(group.id)")
                    }
                    ForEach(group.entries) { entry in
                        Button {
                            searchFocused = false
                            _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            store.open(entry)
                        } label: {
                            EntryRow(entry: entry, settings: store.settings).equatable()
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityIdentifier("entry-\(entry.id)")
                        .accessibilityValue(entry.isRead ? "已读" : "未读")
                        .background {
                            if store.settings.autoReadOnScroll { ListReadRowAnchor(id: entry.id, observer: headerScroll) }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { store.toggleStar(entry) } label: {
                                Label(entry.isStarred ? "取消星标" : "星标", systemImage: entry.isStarred ? "star.slash" : "star.fill")
                            }
                            .tint(Theme.star)
                            .accessibilityIdentifier("entry-star-\(entry.id)")
                            Button { store.toggleRead(entry) } label: {
                                Label(entry.isRead ? "标为未读" : "标为已读", systemImage: entry.isRead ? "envelope.badge" : "envelope.open")
                            }
                            .tint(Theme.accent)
                            .accessibilityIdentifier("entry-read-\(entry.id)")
                        }
                        .contextMenu {
                            Button { store.toggleStar(entry) } label: { Label(entry.isStarred ? "取消星标" : "添加星标", systemImage: "star") }
                            Button { store.toggleRead(entry) } label: { Label(entry.isRead ? "标为未读" : "标为已读", systemImage: "checkmark.circle") }
                        }
                    }
                }

                if store.hasMore || store.listPageError != nil {
                    HStack(spacing: 7) {
                        if store.isLoadingMore {
                        ProgressView().controlSize(.small).tint(Theme.text3)
                        Text("正在加载更多…")
                        } else if store.listPageError != nil {
                            Button("加载未完成，点此重试") { store.retryLoadMore() }
                                .accessibilityIdentifier("retry-reader-page")
                        } else { Text("继续上滑加载") }
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
                }
                if store.settings.autoReadOnScroll && !store.hasMore {
                    bottomReadHint
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                }
            }
        }
        .listStyle(.plain)
        // The overlay is reserved by the spacer, not by an additional system top margin.
        // A zero initial spacer/date row must not be expanded to List's default 44pt minimum.
        .environment(\.defaultMinListRowHeight, 0)
        .listRowSpacing(0)
        .contentMargins(.top, 0, for: .scrollContent)
        .accessibilityIdentifier("article-list")
        .accessibilityValue("\(store.entries.count) 篇已加载")
        .scrollContentBackground(.hidden)
        .background(AmbientBackground())
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottomClearance) }
        .refreshable { await store.refreshCurrent() }
    }

    private var bottomReadHint: some View {
        let unread = store.listSnapshot.unreadCount
        let text: String
        if unread == 0 { text = "当前列表已读完" }
        else if store.isRefreshing || store.isLoadingMore { text = "正在更新列表…" }
        else if sweepReady { text = "松手，将剩余 \(unread) 篇标为已读" }
        else { text = "已经到底了 · 继续上滑，标记剩余 \(unread) 篇已读" }
        return HStack(spacing: 8) {
            Image(systemName: unread == 0 ? "checkmark.circle" : (sweepReady ? "arrow.up.circle.fill" : "arrow.up.circle"))
                .font(.system(size: 15, weight: .medium))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2)
        }
        .foregroundStyle(sweepReady || unread == 0 ? Theme.accent : Theme.text3)
        .padding(.horizontal, 20)
        // Keep the footer height stable when the last rows become read.
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("list-bottom-read-hint")
        .accessibilityValue(unread == 0 ? "complete" : (sweepReady ? "ready" : "continue"))
    }

    @ViewBuilder
    private var emptyView: some View {
        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "没有找到",
                message: "换个关键词试试",
                primary: EmptyAction(title: "清除搜索") {
                    store.clearSearch()
                    searchActive = false
                }
            )
        } else if store.feeds.isEmpty {
            EmptyStateView(
                icon: "dot.radiowaves.left.and.right",
                title: "还没有订阅",
                message: "先去订阅几个喜欢的博客，\n文章会出现在这里。",
                primary: EmptyAction(title: "去订阅") {
                    store.selectedTab = .feeds
                }
            )
        } else if isStarredScope {
            EmptyStateView(
                icon: "star",
                title: "还没有星标",
                message: "在列表里左滑文章，\n或在阅读页点右上角的星标。",
                primary: EmptyAction(title: "回到文章") {
                    store.setScope(.articles)
                    store.selectedTab = .articles
                }
            )
        } else if store.listIsUnreadOnly {
            EmptyStateView(
                icon: "checkmark.circle",
                title: "都读完了",
                message: "当前没有未读文章，可以看看全部。",
                primary: EmptyAction(title: "看全部") {
                    store.settings.listView = .all
                },
                secondary: EmptyAction(title: "刷新") {
                    Task { await store.refreshCurrent() }
                }
            )
        } else {
            EmptyStateView(
                icon: "tray",
                title: "这里还没有文章",
                message: "下拉刷新一下，或者添加新的订阅。",
                primary: EmptyAction(title: "刷新") {
                    Task { await store.refreshCurrent() }
                }
            )
        }
    }
}

// Anchor inside a real list cell so its nearest scroll ancestor is always this list.
// The screen owns the observer; recycling the spacer cell must not end gesture observation.
private struct ListScrollAnchor: UIViewRepresentable {
    let observer: ListHeaderGestureObserver
    let headerHeight: CGFloat

    func makeUIView(context: Context) -> ScrollProbeView {
        let view = ScrollProbeView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.onMount = { [weak observer] view in observer?.attach(above: view) }
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ScrollProbeView, context: Context) {
        observer.attach(above: view)
        let height = headerHeight
        view.onLayout = { [weak observer] view in observer?.headerSpacerDidLayout(view, height: height) }
    }
}

private final class ListHeaderGestureObserver: NSObject, ObservableObject {
    let nextPage = PassthroughSubject<Void, Never>()
    let visibility = PassthroughSubject<Bool, Never>()
    let passedEntries = PassthroughSubject<Set<String>, Never>()
    let sweepRead = PassthroughSubject<Void, Never>()
    let sweepReadiness = PassthroughSubject<Bool, Never>()
    #if DEBUG
    @Published private(set) var diagnostic = "not-attached"
    #else
    var diagnostic: String { "" }
    #endif
    private weak var scrollView: UIScrollView?
    private var policy = ListHeaderScrollPolicy()
    private var observing = false
    private var active = true
    private var readEnabled = false
    private var readPolicy = ListAutoReadPolicy()
    private var rowViews: [String: WeakReadRow] = [:]
    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var paginationEnabled = false
    private var paginationSent = false
    private var rowCollectionQueued = false
    private var scrollUpdateQueued = false
    private var readFlush: DispatchWorkItem?
    private var pendingReadIDs: Set<String> = []
    private var lastClampedOffset: CGFloat = 0
    private var scrollingUp = false
    private var sweepEnabled = false
    private var sweepPolicy = ListBottomSweepPolicy()
    private var sweepStart = CGPoint.zero
    private var sweepEpoch = 0
    private var sweepWasReady = false
    private var sweepTouch: ListSweepTouchRecognizer?
    private var headerLayoutRevision = UUID()
    private var wasAtTopBeforeHeaderChange: Bool?
    private var pendingHeaderHeight: CGFloat?

    func captureTopBeforeHeaderChange() {
        guard let scroll = scrollView else { return }
        wasAtTopBeforeHeaderChange = scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1
        recordDiagnostic("header capture top=\(wasAtTopBeforeHeaderChange == true)")
    }

    // UICollectionView preserves its first visible row when a spacer grows. Capture the top
    // position before keyboard focus, then wait for the actual replacement cell to lay out.
    func preserveTopDuringHeaderRelayout(to height: CGFloat) {
        guard active, let scroll = scrollView else { return }
        let pinToTop = wasAtTopBeforeHeaderChange ?? (scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1)
        wasAtTopBeforeHeaderChange = nil
        guard pinToTop, !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
        headerLayoutRevision = UUID()
        pendingHeaderHeight = height
        resetReadTracking()
        recordDiagnostic("awaiting header cell height=\(Int(height))")
    }

    func headerSpacerDidLayout(_ view: UIView, height: CGFloat) {
        guard let pending = pendingHeaderHeight, abs(height - pending) < 0.5,
              abs(view.bounds.height - height) < 0.5 else { return }
        pendingHeaderHeight = nil
        let revision = headerLayoutRevision
        DispatchQueue.main.async { [weak self] in
            self?.recordDiagnostic("measured header cell height=\(Int(height))")
            self?.alignHeaderTop(revision: revision, remaining: 1)
        }
    }

    private func alignHeaderTop(revision: UUID, remaining: Int) {
        guard active, revision == headerLayoutRevision, let scroll = scrollView,
              !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
        scroll.layoutIfNeeded()
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: false)
        if remaining > 0 {
            DispatchQueue.main.async { [weak self] in self?.alignHeaderTop(revision: revision, remaining: remaining - 1) }
        }
        recordDiagnostic("header top aligned")
    }

    func setPaginationEnabled(_ enabled: Bool) {
        guard enabled != paginationEnabled else { return }
        paginationEnabled = enabled; paginationSent = false
        scheduleScrollUpdate()
    }

    func listChanged() {
        paginationSent = false
        scheduleScrollUpdate()
    }

    func scrollToTop(animated: Bool) {
        headerLayoutRevision = UUID(); pendingHeaderHeight = nil; wasAtTopBeforeHeaderChange = nil
        resetReadTracking()
        guard let scroll = scrollView else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top), animated: animated)
    }

    private func checkPagination(_ scroll: UIScrollView) {
        guard active, paginationEnabled, !paginationSent else { return }
        let remaining = scroll.contentSize.height - scroll.bounds.maxY + scroll.adjustedContentInset.bottom
        guard remaining <= 900 else { return }
        paginationSent = true
        self.nextPage.send(Void())
    }

    private func scheduleScrollUpdate() {
        guard active, !scrollUpdateQueued else { return }
        scrollUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollUpdateQueued = false
            guard let scroll = self.scrollView, self.observing else { return }
            self.checkPagination(scroll)
            self.scrolled(scroll)
        }
    }

    func setSweepEnabled(_ enabled: Bool) {
        guard sweepEnabled != enabled else { return }
        sweepEnabled = enabled
        cancelSweep()
    }

    func cancelSweep() {
        sweepEpoch += 1
        sweepPolicy.cancel()
        publishSweepReadiness()
    }

    private func publishSweepReadiness() {
        guard sweepWasReady != sweepPolicy.ready else { return }
        sweepWasReady = sweepPolicy.ready
        sweepReadiness.send(sweepWasReady)
    }

    private func beginSweep(at point: CGPoint) {
        cancelSweep()
        guard let scroll = scrollView else { return }
        sweepStart = point
        let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        sweepPolicy.begin(enabled: active && readEnabled && sweepEnabled, atBottom: scroll.contentOffset.y >= bottom - 4)
    }

    private func moveSweep(to point: CGPoint, touches: Int) {
        sweepPolicy.move(x: point.x - sweepStart.x, y: point.y - sweepStart.y, touches: touches)
        publishSweepReadiness()
    }

    private func endSweep(at point: CGPoint) {
        let commit = sweepPolicy.end(x: point.x - sweepStart.x, y: point.y - sweepStart.y)
        publishSweepReadiness()
        let epoch = sweepEpoch
        if commit {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.readEnabled, self.sweepEnabled, self.sweepEpoch == epoch else { return }
                self.sweepRead.send(())
            }
        }
    }

    func setAutoReadEnabled(_ enabled: Bool) {
        guard readEnabled != enabled else { return }
        readEnabled = enabled
        resetReadTracking()
    }

    func resetReadTracking() {
        cancelSweep()
        readFlush?.cancel()
        readFlush = nil
        pendingReadIDs.removeAll()
        readPolicy.reset()
        scrollingUp = false
        collectRows()
    }

    func registerRow(id: String, view: UIView) {
        guard rowViews[id]?.view !== view else { return }
        rowViews[id] = WeakReadRow(view)
        guard readEnabled, active, !rowCollectionQueued else { return }
        rowCollectionQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rowCollectionQueued = false
            self.collectRows()
        }
    }

    private func collectRows() {
        guard readEnabled, active, let scroll = scrollView else { return }
        let top = scroll.bounds.minY + scroll.adjustedContentInset.top
        let bottom = scroll.bounds.maxY - scroll.adjustedContentInset.bottom
        rowViews = rowViews.filter { $0.value.view?.window != nil }
        for (id, weakRow) in rowViews {
            guard let view = weakRow.view else { continue }
            let rect = view.convert(view.bounds, to: scroll)
            readPolicy.record(id: id, top: rect.minY, bottom: rect.maxY, viewportTop: top, viewportBottom: bottom)
        }
    }

    private func scrolled(_ scroll: UIScrollView) {
        guard readEnabled, active else { return }
        let minOffset = -scroll.adjustedContentInset.top
        let maxOffset = max(minOffset, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let offset = min(maxOffset, max(minOffset, scroll.contentOffset.y))
        let delta = offset - lastClampedOffset
        guard abs(delta) > 0.5 else { return }
        lastClampedOffset = offset
        collectRows()
        guard scrollingUp, scroll.isDragging || scroll.isDecelerating, delta > 0.5 else { return }
        let ids = readPolicy.passed(above: scroll.bounds.minY + scroll.adjustedContentInset.top)
        readPolicy.consume(ids)
        pendingReadIDs.formUnion(ids)
        if !pendingReadIDs.isEmpty { scheduleReadFlush() }
    }

    private func scheduleReadFlush() {
        guard readFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.readFlush = nil
            guard self.active, self.readEnabled, let scroll = self.scrollView else { return }
            // Track crossings while moving, but save and publish once the drag
            // and its inertia have ended. Disk writes must not compete with it.
            if scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
                self.scheduleReadFlush()
                return
            }
            let ids = self.pendingReadIDs
            self.pendingReadIDs.removeAll()
            if !ids.isEmpty { self.passedEntries.send(ids) }
        }
        readFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    func attach(above view: UIView, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self, weak view] in
            guard let self, let view else { return }
            var ancestor = view.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView {
                    if self.scrollView !== scroll {
                        self.suspendObservation()
                        self.scrollView = scroll
                    }
                    if self.active { self.startObservation() }
                    return
                }
                ancestor = current.superview
            }
            if attempt < 20 { self.attach(above: view, attempt: attempt + 1) }
        }
    }

    func resume() {
        active = true
        startObservation()
    }

    func suspend() {
        headerLayoutRevision = UUID(); pendingHeaderHeight = nil; wasAtTopBeforeHeaderChange = nil
        active = false
        suspendObservation()
    }

    private func startObservation() {
        guard !observing, let scrollView else { return }
        policy.reset()
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        let touch = ListSweepTouchRecognizer(target: nil, action: nil)
        touch.onBegin = { [weak self] point in self?.beginSweep(at: point) }
        touch.onMove = { [weak self] point, count in self?.moveSweep(to: point, touches: count) }
        touch.onEnd = { [weak self] point in self?.endSweep(at: point) }
        touch.onCancel = { [weak self] in self?.cancelSweep() }
        scrollView.addGestureRecognizer(touch)
        sweepTouch = touch
        lastClampedOffset = scrollView.contentOffset.y
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.scheduleScrollUpdate() }
        sizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.scheduleScrollUpdate() }
        observing = true
        scheduleScrollUpdate()
        recordDiagnostic("attached to \(type(of: scrollView))")
    }

    private func suspendObservation() {
        cancelSweep()
        if let sweepTouch { scrollView?.removeGestureRecognizer(sweepTouch) }
        sweepTouch = nil
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
        offsetObservation?.invalidate()
        offsetObservation = nil
        sizeObservation?.invalidate(); sizeObservation = nil
        readFlush?.cancel()
        readFlush = nil
        pendingReadIDs.removeAll()
        readPolicy.reset()
        scrollingUp = false
        observing = false
        policy.reset()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let scroll = scrollView else { return }
        switch gesture.state {
        case .began:
            headerLayoutRevision = UUID(); pendingHeaderHeight = nil; wasAtTopBeforeHeaderChange = nil
            policy.reset()
            scrollingUp = false
            collectRows()
            recordDiagnostic("drag began")
        case .changed:
            let translation = gesture.translation(in: nil)
            let velocity = gesture.velocity(in: nil)
            if abs(translation.y) > abs(translation.x), gesture.numberOfTouches <= 1 {
                scrollingUp = velocity.y < 0
            } else { scrollingUp = false }
            let contentHeight = scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom
            if let visible = policy.update(x: translation.x, y: translation.y,
                                           canScroll: contentHeight > scroll.bounds.height + 8,
                                           singleTouch: gesture.numberOfTouches <= 1) {
                recordDiagnostic("requested visible=\(visible); y=\(Int(translation.y))")
                visibility.send(visible)
            }
        case .ended:
            let velocity = gesture.velocity(in: nil)
            scrollingUp = velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
            policy.reset()
        case .cancelled, .failed:
            scrollingUp = false
            policy.reset()
        default: break
        }
    }

    private func recordDiagnostic(_ value: String) {
        #if DEBUG
        if let screen = DesignPreviewData.requestedScreen, ["scroll-regression", "features-regression"].contains(screen) {
            let offset = Int(scrollView?.contentOffset.y ?? 0), top = Int(scrollView?.adjustedContentInset.top ?? 0)
            let detail = "\(value); offset=\(offset); insetTop=\(top)"
            if diagnostic != detail { diagnostic = detail }
        }
        #endif
    }
}

// Passive touch observation records the edge at touch-down, before UIScrollView
// has moved. It neither recognizes nor prevents scrolling, taps or swipe actions.
private final class ListSweepTouchRecognizer: UIGestureRecognizer {
    var onBegin: ((CGPoint) -> Void)?
    var onMove: ((CGPoint, Int) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private weak var trackedTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, event.allTouches?.count == 1, let touch = touches.first else {
            onCancel?(); state = .failed; return
        }
        trackedTouch = touch
        onBegin?(touch.location(in: nil))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = trackedTouch { onMove?(touch.location(in: nil), event.allTouches?.count ?? 0) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = trackedTouch, touches.contains(touch) { onEnd?(touch.location(in: nil)) }
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onCancel?(); state = .failed
    }
    override func reset() { super.reset(); trackedTouch = nil }
}

private final class WeakReadRow {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}

private struct ListReadRowAnchor: UIViewRepresentable {
    let id: String
    let observer: ListHeaderGestureObserver
    func makeUIView(context: Context) -> ScrollProbeView {
        let view = ScrollProbeView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.onMount = { [weak observer] view in observer?.registerRow(id: id, view: view) }
        observer.registerRow(id: id, view: view)
        return view
    }
    func updateUIView(_ view: ScrollProbeView, context: Context) { observer.registerRow(id: id, view: view) }
}

private final class ScrollProbeView: UIView {
    var onMount: ((UIView) -> Void)?
    var onLayout: ((UIView) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMount?(self) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil { onLayout?(self) }
    }
}
