import SwiftUI
import UIKit
import WebKit

enum ReaderLoadingStage: Equatable {
    case fetching, reading, rendering
    var message: String {
        switch self {
        case .fetching: return "正在抓取全文…"
        case .reading: return "正在加载原文…"
        case .rendering: return "正在显示正文…"
        }
    }
    static func resolve(fetching: Bool, reading: Bool, rendering: Bool) -> ReaderLoadingStage? {
        if fetching { return .fetching }
        if reading { return .reading }
        return rendering ? .rendering : nil
    }
}

struct ReaderView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var headerVisible = true
    @State private var pullActive = false
    @State private var turnRequest: ReaderTurnRequest?
    @State private var backOffset: CGFloat = 0
    @State private var isDismissing = false
    @State private var originalDrag: CGFloat = 0
    @State private var originalReady = false
    @State private var showAppearance = false
    @State private var showWorkspaceTools = false
    @State private var readingProgress: Double = 0
    @State private var imagePresentation: ImagePresentation?
    @State private var videoPresentation: VideoPresentation?
    @State private var renderingArticleID: String?
    @State private var renderFailure: String?
    @State private var retryRequest: UUID?
    @State private var displayedLoadingStage: ReaderLoadingStage?

    private var loadingStage: ReaderLoadingStage? {
        ReaderLoadingStage.resolve(fetching: store.readerLoadingFulltext, reading: store.readerLoadingBody,
                                   rendering: renderingArticleID != nil && renderingArticleID == store.readerEntry?.id)
    }

    var body: some View {
        GeometryReader { geometry in
            if let entry = store.readerEntry {
                content(entry, width: geometry.size.width)
                    .offset(x: backOffset)
            }
        }
        .task(id: "\(store.readerEntry?.id ?? "")-\(loadingStage?.message ?? "")") {
            if let stage = loadingStage { displayedLoadingStage = stage }
            else {
                // Bridge the run-loop gap between an awaited fetch and UIViewRepresentable's render callback.
                // Only the indicator is held; content and network completion are never delayed.
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
                displayedLoadingStage = nil
            }
        }
    }

    private func content(_ entry: Entry, width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            ReaderWebView(
                html: store.readerHTML,
                contentID: entry.id,
                baseURL: URL(string: entry.url),
                nextPage: store.readerNextPage,
                previousPage: store.readerPreviousPage,
                turnRequest: turnRequest,
                onTurn: { store.turnReader($0, expectedID: $1) },
                onReaderAction: { action in
                    if action.host == "source" { store.toggleReaderSource() }
                    else if action.host == "extract" { Task { await store.extractFulltext() } }
                    else if action.host == "image", let image = ReaderMedia.image(from: action) {
                        let items = ReaderMedia.images(in: store.readerHTML)
                        imagePresentation = ImagePresentation(images: items.isEmpty ? [image] : items,
                                                              index: items.firstIndex(where: { $0.id == image.id }) ?? 0, referer: entry.url)
                    } else if action.host == "video", let raw = URLComponents(url: action, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                              let url = ReaderMedia.httpURL(raw) {
                        videoPresentation = VideoPresentation(url: url)
                    }
                },
                onOpenExternal: { openExternal($0) },
                onBackDrag: { distance in
                    guard !isDismissing else { return }
                    backOffset = max(0, distance)
                },
                onBackEnd: { distance, velocity, cancelled in
                    guard !isDismissing else { return }
                    if !cancelled && (distance > 90 || (distance > 40 && velocity > 500)) {
                        isDismissing = true
                        withAnimation(.easeOut(duration: 0.2)) { backOffset = width }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard store.readerEntry?.id == entry.id else {
                                isDismissing = false
                                backOffset = 0
                                return
                            }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { store.closeReader() }
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.22)) { backOffset = 0 }
                    }
                },
                onOriginalDrag: { distance in
                    guard !isDismissing else { return }
                    originalDrag = distance
                    originalReady = ReaderEdgePolicy.isReady(distance: distance)
                },
                onOriginalEnd: { distance, velocityX, cancelled in
                    let commit = !isDismissing &&
                        ReaderEdgePolicy.shouldCommit(distance: distance, velocityX: velocityX, cancelled: cancelled)
                    withAnimation(.easeOut(duration: 0.2)) {
                        originalDrag = 0
                        originalReady = false
                    }
                    if commit { openOriginal(entry) }
                },
                onPullActive: { pullActive = $0 },
                onProgress: { readingProgress = $0 },
                onShowHeader: { visible in
                    guard headerVisible != visible else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        headerVisible = visible
                    }
                },
                retryRequest: retryRequest,
                onContentLoading: { id, loading, failure in
                    guard store.readerEntry?.id == id else { return }
                    renderingArticleID = loading ? id : nil
                    renderFailure = failure
                }
            )
            .ignoresSafeArea(edges: .bottom)

            header(entry)
                .opacity(headerVisible ? 1 : 0)
                .offset(y: headerVisible ? 0 : -70)
                .allowsHitTesting(!pullActive)

            if !headerVisible {
                floatingBack
                    .transition(.opacity)
                    .allowsHitTesting(!pullActive)
            }

            originalEdgeHint
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
                .allowsHitTesting(false)

            // Keep one stable status view through the network-to-WebKit handoff.
            loadingOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if headerVisible && !pullActive {
                HStack {
                    Button { turnRequest = ReaderTurnRequest(direction: .previous) } label: {
                        Image(systemName: "chevron.up").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("上一篇文章")
                    Spacer()
                    Text("\(Int(readingProgress * 100))%")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Button { turnRequest = ReaderTurnRequest(direction: .next) } label: {
                        HStack(spacing: 6) {
                            Text("下一篇").font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        }.frame(minHeight: 44)
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 20)
                .background(.regularMaterial)
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showAppearance) {
            ReadingAppearanceSheet().environmentObject(store)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWorkspaceTools) {
            if let connection = store.workspace, let entry = store.readerEntry, let id = Int(entry.id) {
                connection.articleTools(id, entry.title, entry.url)
            }
        }
        .fullScreenCover(item: $imagePresentation) { ArticleImageViewer(presentation: $0) }
        .fullScreenCover(item: $videoPresentation) { ArticleVideoPlayer(presentation: $0) }
        .onChange(of: store.readerEntry?.id) { _, _ in
            headerVisible = true
            renderingArticleID = nil; renderFailure = nil
        }
        .onDisappear { renderingArticleID = nil; renderFailure = nil; displayedLoadingStage = nil }
    }

    private func openExternal(_ url: URL) {
        if store.settings.openInBrowser {
            store.openInAppBrowser(url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    private func openOriginal(_ entry: Entry) {
        guard let url = URL(string: entry.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            store.showBanner("这篇文章没有原文链接", isError: true)
            return
        }
        openExternal(url)
    }

    private var originalEdgeHint: some View {
        let ready = originalReady
        let progress = min(1, originalDrag / ReaderEdgePolicy.commitDistance)
        return HStack(spacing: 6) {
            Image(systemName: ready ? "arrow.left.circle.fill" : "chevron.left")
                .font(.system(size: 13, weight: .medium))
            Text(ReaderEdgePolicy.hint(ready: ready))
                .font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(ready ? Theme.accent : Theme.text2)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
        .offset(x: ReaderEdgePolicy.offset(distance: originalDrag))
        .opacity(originalDrag > 0 ? min(1, 0.3 + progress * 0.7) : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: ready)
        .accessibilityHidden(true)
    }

    private func header(_ entry: Entry) -> some View {
        HStack(spacing: 4) {
            Button {
                store.closeReader()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回文章列表")

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.feedTitle.isEmpty ? "未读" : entry.feedTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(Format.dayTime(entry.date))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            Button {
                store.toggleStar(entry)
            } label: {
                Image(systemName: entry.isStarred ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(entry.isStarred ? Theme.star : Theme.text2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isStarred ? "取消星标" : "添加星标")

            Button { showAppearance = true } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("阅读排版")

            Menu {
                if store.workspace != nil {
                    Button { showWorkspaceTools = true } label: { Label("AI 解读与文章操作", systemImage: "sparkles") }
                    Divider()
                }
                if let url = URL(string: entry.url), !entry.url.isEmpty {
                    ShareLink(item: url) { Label("分享文章", systemImage: "square.and.arrow.up") }
                    Divider()
                }
                Button {
                    turnRequest = ReaderTurnRequest(direction: .previous)
                } label: {
                    Label("上一篇文章", systemImage: "chevron.up")
                }
                Button {
                    turnRequest = ReaderTurnRequest(direction: .next)
                } label: {
                    Label("下一篇未读", systemImage: "chevron.down")
                }
                Divider()
                Button {
                    Task { await store.extractFulltext() }
                } label: {
                    Label(entry.hasFulltext ? "查看抓取的正文" : "抓正文", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(entry.url.isEmpty || store.readerLoadingFulltext)
                if store.readerCanSwitchSource {
                    Button { store.toggleReaderSource() } label: {
                        Label(store.readerShowsFulltext ? "看订阅源原文" : "看抓取的正文", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                if entry.hasFulltext && store.workspace == nil {
                    Button { Task { await store.extractFulltext(force: true) } } label: {
                        Label("重新抓取正文", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.readerLoadingFulltext)
                }

                Button {
                    store.markReaderUnread()
                } label: {
                    Label("标为未读", systemImage: "envelope.badge")
                }

                if let url = URL(string: entry.url), !entry.url.isEmpty {
                    Divider()
                    if store.settings.openInBrowser {
                        Button {
                            store.openInAppBrowser(url)
                        } label: {
                            Label("用内置浏览器打开", systemImage: "globe")
                        }
                    }
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("在 Safari 打开", systemImage: "safari")
                    }
                    Button {
                        UIPasteboard.general.string = entry.url
                        store.showBanner("链接已复制", isError: false)
                    } label: {
                        Label("复制链接", systemImage: "doc.on.doc")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("阅读操作")
            .accessibilityIdentifier("reader-article-actions")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    private var floatingBack: some View {
        VStack {
            HStack {
                Button {
                    store.closeReader()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Theme.line, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.top, 8)
    }

    private var loadingOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                if let stage = displayedLoadingStage {
                    ProgressView().controlSize(.small).tint(Theme.text2)
                    Text(stage.message).accessibilityIdentifier("reader-loading-message")
                } else if let renderFailure {
                    Image(systemName: "exclamationmark.circle")
                    Text(renderFailure)
                    Button("重试") {
                        renderingArticleID = store.readerEntry?.id
                        self.renderFailure = nil
                        retryRequest = UUID()
                    }.foregroundStyle(Theme.accent).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("reader-render-retry")
                }
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
            .opacity(displayedLoadingStage != nil || renderFailure != nil ? 1 : 0)
            .accessibilityHidden(displayedLoadingStage == nil && renderFailure == nil)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: displayedLoadingStage)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: renderFailure)
        }
        .padding(.top, headerVisible ? 64 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(displayedLoadingStage == nil && renderFailure != nil)
    }
}
