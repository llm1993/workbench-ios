import SwiftUI
import UIKit
import WebKit

struct BrowserRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

final class BrowserModel: ObservableObject {
    @Published var title = ""
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = true
    @Published var progress: Double = 0
    @Published var errorText: String?

    weak var webView: WKWebView?
    private let initialURL: URL

    init(url: URL) {
        initialURL = url
        self.url = url
    }

    var host: String {
        url?.host ?? ""
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return host.isEmpty ? "网页" : host
    }

    var currentURL: URL {
        webView?.url ?? url ?? initialURL
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func stop() { webView?.stopLoading() }

    func reload() {
        errorText = nil
        guard let web = webView else { return }
        if web.url == nil {
            retry()
        } else {
            web.reload()
        }
    }

    func retry() {
        errorText = nil
        isLoading = true
        webView?.load(URLRequest(url: currentURL))
    }
}

struct InAppBrowserView: View {
    let request: BrowserRequest
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: BrowserModel
    @State private var dismissOffset: CGFloat = 0
    @State private var isDismissing = false

    init(request: BrowserRequest) {
        self.request = request
        _model = StateObject(wrappedValue: BrowserModel(url: request.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            progressBar
            ZStack {
                BrowserWebView(url: request.url, model: model,
                               onEdgeDrag: handleEdgeDrag,
                               onEdgeEnd: handleEdgeEnd)
                if let message = model.errorText {
                    errorView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            toolbar
        }
        .background(Theme.background.ignoresSafeArea())
        .offset(x: dismissOffset)
    }

    private func handleEdgeDrag(_ distance: CGFloat) {
        guard !isDismissing else { return }
        dismissOffset = max(0, distance)
    }

    private func handleEdgeEnd(_ distance: CGFloat, velocity: CGFloat, cancelled: Bool, width: CGFloat) {
        guard !isDismissing else { return }
        if !cancelled && (distance > 90 || (distance > 40 && velocity > 500)) {
            isDismissing = true
            withAnimation(.easeOut(duration: 0.2)) { dismissOffset = width }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                dismiss()
            }
        } else {
            withAnimation(.easeOut(duration: 0.22)) { dismissOffset = 0 }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭浏览器")
            .accessibilityIdentifier("browser-close")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayTitle)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(model.host)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            ShareLink(item: model.currentURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("分享网页")

            Menu {
                Button {
                    UIPasteboard.general.string = model.currentURL.absoluteString
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
                Button {
                    UIApplication.shared.open(model.currentURL)
                } label: {
                    Label("在 Safari 打开", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("网页操作")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.line)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: proxy.size.width * min(1, max(0, model.progress)))
            }
        }
        .frame(height: 2)
        .opacity(model.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.22), value: model.progress)
        .animation(.easeOut(duration: 0.22), value: model.isLoading)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolButton("chevron.left", label: "后退", enabled: model.canGoBack) { model.goBack() }
                .accessibilityIdentifier("browser-back")
            toolButton("chevron.right", label: "前进", enabled: model.canGoForward) { model.goForward() }
            Spacer()
            if model.isLoading {
                toolButton("xmark.circle", label: "停止加载") { model.stop() }
            } else {
                toolButton("arrow.clockwise", label: "刷新") { model.reload() }
            }
            toolButton("safari", label: "在 Safari 打开") { UIApplication.shared.open(model.currentURL) }
                .accessibilityIdentifier("browser-safari")
        }
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    private func toolButton(_ systemName: String, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? Theme.text2 : Theme.text3.opacity(0.4))
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func errorView(_ message: String) -> some View {
        VStack {
            Spacer()
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "网页打不开",
                message: message,
                primary: EmptyAction(title: "重试") { model.retry() },
                secondary: EmptyAction(title: "在 Safari 打开") { UIApplication.shared.open(model.currentURL) }
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let url: URL
    let model: BrowserModel
    let onEdgeDrag: (CGFloat) -> Void
    let onEdgeEnd: (CGFloat, CGFloat, Bool, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(model: model)
        coordinator.onEdgeDrag = onEdgeDrag
        coordinator.onEdgeEnd = onEdgeEnd
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        // The edge swipe returns to the reader; in-page history lives in the toolbar.
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = true
        web.backgroundColor = UIColor(Theme.background)
        web.underPageBackgroundColor = UIColor(Theme.background)
        web.scrollView.keyboardDismissMode = .onDrag
        web.accessibilityIdentifier = "browser-webview"
        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(Theme.accent)
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        let back = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleBackPan(_:)))
        back.maximumNumberOfTouches = 1
        back.cancelsTouchesInView = false
        back.delegate = context.coordinator
        web.addGestureRecognizer(back)
        #if DEBUG
        web.isInspectable = true
        #endif
        context.coordinator.attach(web)
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEdgeDrag = onEdgeDrag
        context.coordinator.onEdgeEnd = onEdgeEnd
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
        private let model: BrowserModel
        private var observations: [NSKeyValueObservation] = []
        var onEdgeDrag: ((CGFloat) -> Void)?
        var onEdgeEnd: ((CGFloat, CGFloat, Bool, CGFloat) -> Void)?
        // A swipe only returns to the reader when it starts on the very edge, so the
        // page keeps its own horizontal scrolling.
        private static let edgeStartWidth: CGFloat = 20

        init(model: BrowserModel) {
            self.model = model
        }

        func attach(_ web: WKWebView) {
            model.webView = web
            observations = [
                web.observe(\.title, options: [.new]) { [weak self, weak web] _, _ in
                    guard let web else { return }
                    self?.onMain { $0.title = web.title ?? "" }
                },
                web.observe(\.url, options: [.new]) { [weak self, weak web] _, _ in
                    guard let web, let url = web.url else { return }
                    self?.onMain { $0.url = url }
                },
                web.observe(\.canGoBack, options: [.new]) { [weak self, weak web] _, _ in
                    guard let web else { return }
                    self?.onMain { $0.canGoBack = web.canGoBack }
                },
                web.observe(\.canGoForward, options: [.new]) { [weak self, weak web] _, _ in
                    guard let web else { return }
                    self?.onMain { $0.canGoForward = web.canGoForward }
                },
                web.observe(\.estimatedProgress, options: [.new]) { [weak self, weak web] _, _ in
                    guard let web else { return }
                    self?.onMain { $0.progress = web.estimatedProgress }
                },
                web.observe(\.isLoading, options: [.new]) { [weak self, weak web] _, _ in
                    guard let web else { return }
                    self?.onMain { $0.isLoading = web.isLoading }
                    if !web.isLoading {
                        DispatchQueue.main.async { web.scrollView.refreshControl?.endRefreshing() }
                    }
                }
            ]
        }

        func invalidate() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            onEdgeDrag = nil
            onEdgeEnd = nil
            model.webView = nil
        }

        @objc func handleBackPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            // Window coordinates: the view slides right under the finger, so measuring
            // in its own space would feed the offset straight back into the translation.
            let translation = gesture.translation(in: nil).x
            let width = view.window?.bounds.width ?? view.bounds.width
            switch gesture.state {
            case .changed:
                onEdgeDrag?(max(0, translation))
            case .ended:
                onEdgeEnd?(max(0, translation), gesture.velocity(in: nil).x, false, width)
            case .cancelled, .failed:
                onEdgeEnd?(0, 0, true, width)
            default:
                break
            }
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gesture.view else { return false }
            return touch.location(in: view).x <= Coordinator.edgeStartWidth
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.2
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func refresh(_ sender: UIRefreshControl) {
            model.reload()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onMain { $0.errorText = nil }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
            onMain {
                $0.isLoading = false
                $0.progress = 1
                $0.errorText = nil
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(webView, error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(webView, error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["http", "https", "about", "blob", "data", "file"].contains(scheme) {
                decisionHandler(.allow)
                return
            }
            if ["mailto", "tel", "sms", "facetime", "maps", "itms-apps"].contains(scheme) {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    webView.load(navigationAction.request)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        private func fail(_ webView: WKWebView, _ error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
            let failure = error as NSError
            if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
            // WebKit reports frame loads replaced by our own navigation as failures.
            if failure.domain == "WebKitErrorDomain" && failure.code == 102 { return }
            let message: String
            if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorNotConnectedToInternet {
                message = "网络似乎不可用，检查连接后再试。"
            } else if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorTimedOut {
                message = "网页加载超时，可以重试或改用 Safari 打开。"
            } else if failure.domain == NSURLErrorDomain && (failure.code == NSURLErrorCannotFindHost || failure.code == NSURLErrorCannotConnectToHost) {
                message = "找不到这个网站，检查链接是否仍然有效。"
            } else {
                message = failure.localizedDescription
            }
            onMain {
                $0.errorText = message
                $0.isLoading = false
                $0.progress = 0
            }
        }

        private func onMain(_ change: @escaping (BrowserModel) -> Void) {
            // KVO can fire while SwiftUI is installing the web view; publishing
            // synchronously during that update logs undefined-behavior warnings.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                change(self.model)
            }
        }
    }
}
