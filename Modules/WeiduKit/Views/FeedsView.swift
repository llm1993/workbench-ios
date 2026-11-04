import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FeedsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.hostAppActions) private var appActions
    @Environment(\.readerBottomClearance) private var bottomClearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var showShare = false
    @State private var shareURL: URL?
    @State private var pendingDelete: Feed?
    @State private var searchText = ""
    @State private var editingFeed: Feed?

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(
                title: "订阅",
                subtitle: "\(store.feeds.count) 个订阅 · \(store.unreadTotal) 篇未读"
            ) {
                HStack(spacing: 2) {
                    HeaderIconButton(systemName: "plus") { showAdd = true }
                    Menu {
                        appActions()
                        Button {
                            showImporter = true
                        } label: {
                            Label("导入 OPML", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            exportOPML()
                        } label: {
                            Label("导出 OPML", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.feeds.isEmpty)
                        Divider()
                        Button {
                            Task { await store.refreshAll() }
                        } label: {
                            Label("全部刷新", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.text2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }

            ScrollViewReader { proxy in
            List {
                Color.clear.frame(height: 1).id("feeds-top")
                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                    .listRowBackground(Theme.background).accessibilityHidden(true)
                if store.feeds.isEmpty {
                    emptyContent
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                        TextField("搜索订阅名称或网站", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除搜索")
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 13)
                    .frame(height: 44)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)

                    if filteredFeeds.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: "没有找到订阅", message: "试试其他名称或网站地址。")
                            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                            .listRowBackground(Theme.background)
                    }
                    ForEach(filteredFeeds) { feed in
                        HStack(spacing: 0) {
                            Button { store.openFeed(feed) } label: {
                                FeedRow(feed: feed, showsChevron: false)
                            }
                            .buttonStyle(RowButtonStyle())
                            Menu {
                                feedActions(feed)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text2)
                                    .frame(width: 44, height: 48)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("订阅操作：\(feed.title)")
                            .accessibilityIdentifier("feed-more-\(feed.id)")
                            .padding(.trailing, 8)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparatorTint(Theme.line)
                        .listRowBackground(Theme.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = feed
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            feedActions(feed)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottomClearance) }
            .refreshable { await store.refreshAll() }
            .onReceive(store.scrollToTop) { tab in
                guard tab == .feeds else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { proxy.scrollTo("feeds-top", anchor: .top) }
            }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showAdd) {
            AddFeedView()
                .environmentObject(store)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ActivityView(items: [shareURL])
            }
        }
        .sheet(item: $editingFeed) { feed in
            FeedReadingSettings(feed: feed).environmentObject(store)
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: opmlTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .confirmationDialog(
            "删除订阅",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let feed = pendingDelete {
                Button("删除「\(feed.title)」", role: .destructive) {
                    store.deleteFeed(feed)
                    pendingDelete = nil
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("这个源下的文章也会一起删掉，已星标的文章也在内。")
        }
    }

    @ViewBuilder
    private func feedActions(_ feed: Feed) -> some View {
        Button {
            UIPasteboard.general.string = feed.url
            store.showBanner("订阅地址已复制", isError: false)
        } label: {
            Label("复制订阅地址", systemImage: "doc.on.doc")
        }
        Button { editingFeed = feed } label: {
            Label("订阅设置", systemImage: "slider.horizontal.3")
        }
        Divider()
        Button(role: .destructive) { pendingDelete = feed } label: {
            Label("删除订阅", systemImage: "trash")
        }
    }

    private var filteredFeeds: [Feed] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.feeds }
        return store.feeds.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.host.localizedCaseInsensitiveContains(query)
        }
    }

    private var opmlTypes: [UTType] {
        var types: [UTType] = [.xml]
        if let type = UTType(filenameExtension: "opml") {
            types.append(type)
        }
        return types
    }

    private var emptyContent: some View {
        VStack(spacing: 0) {
            EmptyStateView(
                icon: "dot.radiowaves.left.and.right",
                title: "还没有订阅",
                message: "粘贴博客或任意网站地址，\n未读会自己找到订阅入口。",
                primary: EmptyAction(title: "添加订阅") { showAdd = true },
                secondary: EmptyAction(title: "导入 OPML") { showImporter = true }
            )

            VStack(alignment: .leading, spacing: 0) {
                Text("推荐订阅")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                ForEach(Recommendations.all.prefix(6)) { item in
                    HStack(spacing: 11) {
                        Circle()
                            .fill(FeedPalette.color(for: item.url))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 14.5))
                                .foregroundStyle(Theme.text)
                            Text(Format.host(item.url))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        if store.isSubscribed(item.url) {
                            Text("已订阅")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        } else {
                            Button("添加") {
                                addRecommended(item)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    Divider().overlay(Theme.line).padding(.leading, 34)
                }
            }
            .padding(.bottom, 26)
        }
    }

    private func addRecommended(_ item: RecommendedFeed) {
        Task {
            do {
                _ = try await store.addFeed(item.url, directTitle: item.title)
            } catch {
                let message = (error as? WeiduError)?.errorDescription ?? error.localizedDescription
                store.showBanner(message, isError: true)
            }
        }
    }

    private func exportOPML() {
        guard let url = ExportedFile.writeOPML(store.opmlText()) else {
            store.showBanner("导出失败，请稍后再试", isError: true)
            return
        }
        shareURL = url
        showShare = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                store.showBanner("读不到这个文件", isError: true)
                return
            }
            Task { _ = await store.importOPML(data) }
        case .failure(let error):
            store.showBanner("导入失败：\(error.localizedDescription)", isError: true)
        }
    }
}
