import SwiftUI
import Combine

struct RootView: View {
    @StateObject private var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tabTapPolicy = ReaderTabTapPolicy()
    @State private var tabBarHeight: CGFloat = 80

    init(workspace: WeiduWorkspaceConnection? = nil) {
        _store = StateObject(wrappedValue: Store(workspace: workspace))
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $store.selectedTab) {
                ArticleListScreen(scope: .articles)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppTab.articles)
                    .tabItem { Label("文章", systemImage: "tray.full") }

                ArticleListScreen(scope: .starred)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppTab.starred)
                    .tabItem { Label("星标", systemImage: "star") }

                FeedsView()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppTab.feeds)
                    .tabItem { Label("订阅", systemImage: "dot.radiowaves.left.and.right") }

                SettingsView()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppTab.settings)
                    .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
            }
            .toolbar(.hidden, for: .tabBar)
            .tint(Theme.accent)
            .environment(\.readerBottomClearance, tabBarHeight)

            if store.readerEntry != nil {
                ReaderView()
                    .transition(.move(edge: .trailing))
                    .zIndex(30)
            }
        }
        .overlay(alignment: .bottom) {
            tabBar
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ReaderTabBarHeightKey.self, value: geometry.size.height)
                    })
                    .opacity(tabBarVisible ? 1 : 0)
                    .offset(y: tabBarVisible || reduceMotion ? 0 : 120)
                    .allowsHitTesting(tabBarVisible)
                    .accessibilityHidden(!tabBarVisible)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: tabBarVisible)
        }
        .onPreferenceChange(ReaderTabBarHeightKey.self) { height in
            if height > 0, abs(tabBarHeight - height) > 0.5 { tabBarHeight = height }
        }
        .overlay(alignment: .bottom) {
            if let banner = store.banner {
                BannerView(banner: banner)
                    .padding(.bottom, tabBarVisible ? tabBarHeight + 8 : 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { store.dismissBanner() }
            }
        }
        .environmentObject(store)
        .fullScreenCover(item: $store.browserRequest) { request in
            InAppBrowserView(request: request)
                .presentationBackground(.clear)
                .preferredColorScheme(store.settings.theme.colorScheme)
        }
        .preferredColorScheme(store.settings.theme.colorScheme)
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeOut(duration: 0.26), value: store.readerEntry != nil)
        .animation(.easeOut(duration: 0.22), value: store.banner)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.setListTabBarVisible(true)
                Task {
                    await store.maintenanceIfNeeded()
                    await store.refreshIfNeeded()
                }
            }
        }
        .onChange(of: store.selectedTab) { _, _ in store.setListTabBarVisible(true) }
        .onChange(of: store.readerEntry?.id) { _, id in if id == nil { store.setListTabBarVisible(true) } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            guard scenePhase == .active else { return }
            Task { await store.maintenanceIfNeeded(now: now) }
        }
        .task {
            await store.maintenanceIfNeeded()
            await store.refreshIfNeeded()
        }
        .onReceive(store.workspace?.navigation.$revision.dropFirst().eraseToAnyPublisher() ?? Empty<UUID, Never>().eraseToAnyPublisher()) { _ in
            guard let navigation = store.workspace?.navigation else { return }
            Task {
                if let feed = navigation.feed {
                    navigation.feed = nil;store.closeReader();store.setScope(.feed(feed));store.selectedTab = .articles;await store.refreshCloud(fetch: false)
                } else if let article = navigation.article { navigation.article = nil; await store.openCloudArticle(article) }
                else {
                    if navigation.closeCurrent || navigation.selectionPending { store.closeReader(); navigation.closeCurrent = false }
                    if navigation.selectionPending { store.setScope(.articles); store.selectedTab = .articles; navigation.selectionPending = false }
                    await store.refreshCloud(fetch: false)
                }
            }
        }
    }

    private var tabBarVisible: Bool {
        store.readerEntry == nil && (store.selectedTab != .articles && store.selectedTab != .starred || store.listTabBarVisible)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.articles, title: "未读", icon: "tray.full")
            tabButton(.starred, title: "星标", icon: "star")
            tabButton(.feeds, title: "订阅", icon: "dot.radiowaves.left.and.right")
            tabButton(.settings, title: "设置", icon: "slider.horizontal.3")
        }
        .padding(.vertical, 8)
        .glassSurface(radius: 28)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func tabButton(_ tab: AppTab, title: String, icon: String) -> some View {
        Button {
            let returnToTop = tabTapPolicy.tap(tab, selected: store.selectedTab)
            store.selectedTab = tab
            if returnToTop { store.handleTabDoubleTap(tab) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                    .frame(width: 50, height: 28)
                    .background(store.selectedTab == tab ? Theme.accentSoft : Color.clear, in: Capsule())
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(store.selectedTab == tab ? Theme.accent : Theme.text2)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("tab-\(tab.rawValue)")
        .accessibilityAddTraits(store.selectedTab == tab ? .isSelected : [])
        .accessibilityHint(tab == .articles || tab == .starred ? "连续点按两次返回顶部并隐藏已读文章" : "连续点按两次返回顶部")
    }
}

private struct ReaderTabBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ReaderBottomClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 80
}

extension EnvironmentValues {
    var readerBottomClearance: CGFloat {
        get { self[ReaderBottomClearanceKey.self] }
        set { self[ReaderBottomClearanceKey.self] = newValue }
    }
}
