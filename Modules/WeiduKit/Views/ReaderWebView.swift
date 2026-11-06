import SwiftUI
import UIKit
import WebKit

// A navigation completion can arrive after a newer HTML document or another article.
// Keep this small state value testable without making a live WebKit request.
struct ReaderRenderingState {
    private(set) var revision = UUID()
    private(set) var contentID = ""
    private(set) var loading = false
    private(set) var failure: String?

    @discardableResult mutating func begin(contentID: String) -> UUID {
        revision = UUID(); self.contentID = contentID; loading = true; failure = nil
        return revision
    }
    @discardableResult mutating func finish(_ revision: UUID, failure: String? = nil) -> Bool {
        guard revision == self.revision, loading else { return false }
        loading = false; self.failure = failure
        return true
    }
    mutating func invalidate() { revision = UUID(); loading = false; failure = nil; contentID = "" }
}

struct ReaderWebView: UIViewRepresentable {
    let html: String
    let contentID: String
    let baseURL: URL?
    let nextPage: ReaderPage?
    let previousPage: ReaderPage?
    let turnRequest: ReaderTurnRequest?
    let onTurn: (ReaderTurnDirection, String) -> Bool
    let onReaderAction: (URL) -> Void
    let onOpenExternal: (URL) -> Void
    let onBackDrag: (CGFloat) -> Void
    let onBackEnd: (CGFloat, CGFloat, Bool) -> Void
    let onOriginalDrag: (CGFloat) -> Void
    let onOriginalEnd: (CGFloat, CGFloat, Bool) -> Void
    let onPullActive: (Bool) -> Void
    let onProgress: (Double) -> Void
    let onShowHeader: (Bool) -> Void
    let retryRequest: UUID?
    let onContentLoading: (String, Bool, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .clear
        container.clipsToBounds = true
        context.coordinator.install(in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
        private enum Phase: String { case idle, dragging, rebounding, waiting, leaving, entering }
        private var parent: ReaderWebView
        private weak var container: UIView?
        private weak var webView: WKWebView?
        private weak var pullGesture: UIPanGestureRecognizer?
        private weak var originalGesture: UIPanGestureRecognizer?
        private var loadedHTML = ""
        private var loadedContentID = ""
        private var activeNavigation: WKNavigation?
        private var rendering = ReaderRenderingState()
        private var invalidated = false
        private var lastRetryRequest: UUID?
        private var restoredProgress: CGFloat?
        private var previousSnapshot: UIView?
        private var observation: NSKeyValueObservation?
        private var phase: Phase = .idle
        private var direction: ReaderTurnDirection?
        private var atTopOnTouch = false
        private var atBottomOnTouch = false
        private var lastOffset: CGFloat = 0
        private var accumulated: CGFloat = 0
        private var headerShown = true
        private var lastProgress = -1
        private var lastRequest: UUID?
        private var targetID: String?
        private var stagingWebView: WKWebView?
        private var stagedPage: ReaderPage?
        private var stagedReady = false
        private var preparationTimeout: DispatchWorkItem?
        private var animator: UIViewPropertyAnimator?
        private let hint = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        private let hintLabel = UILabel()
        private var hintTop: NSLayoutConstraint?
        private var hintBottom: NSLayoutConstraint?
        private var ready = false
        #if DEBUG
        private var initialPositionApplied = false
        private var proofEvents: [[String: Any]] = []
        #endif

        init(_ parent: ReaderWebView) { self.parent = parent }

        func install(in container: UIView) {
            self.container = container
            let web = makeWebView()
            container.addSubview(web)
            web.alpha = 0
            webView = web
            attach(to: web)
            installHint(in: container)
            loadedHTML = parent.html
            loadedContentID = parent.contentID
            lastRetryRequest = parent.retryRequest
            beginRendering()
            activeNavigation = web.loadHTMLString(parent.html, baseURL: parent.baseURL)
        }

        private func beginRendering() {
            rendering.begin(contentID: loadedContentID)
            reportRendering()
        }

        private func reportRendering() {
            let state = rendering
            // UIViewRepresentable updates must not synchronously mutate SwiftUI state.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.invalidated, self.rendering.revision == state.revision,
                      self.rendering.loading == state.loading, self.rendering.failure == state.failure else { return }
                self.parent.onContentLoading(state.contentID, state.loading, state.failure)
            }
        }

        private func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(ImageProxy.shared, forURLScheme: ImageProxy.scheme)
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: container?.bounds ?? .zero, configuration: configuration)
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            web.navigationDelegate = self
            web.uiDelegate = self
            web.isOpaque = false
            web.backgroundColor = .clear
            web.scrollView.backgroundColor = .clear
            web.scrollView.contentInsetAdjustmentBehavior = .never
            web.scrollView.alwaysBounceVertical = true
            web.scrollView.showsVerticalScrollIndicator = false
            return web
        }

        private func installHint(in container: UIView) {
            hint.translatesAutoresizingMaskIntoConstraints = false
            hint.layer.cornerRadius = 22
            hint.clipsToBounds = true
            hint.alpha = 0
            hint.isUserInteractionEnabled = false
            hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
            hintLabel.textColor = .secondaryLabel
            hintLabel.accessibilityIdentifier = "reader-pull-hint"
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            hint.contentView.addSubview(hintLabel)
            container.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                hint.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
                hintLabel.leadingAnchor.constraint(equalTo: hint.contentView.leadingAnchor, constant: 16),
                hintLabel.trailingAnchor.constraint(equalTo: hint.contentView.trailingAnchor, constant: -16),
                hintLabel.topAnchor.constraint(equalTo: hint.contentView.topAnchor, constant: 11),
                hintLabel.bottomAnchor.constraint(equalTo: hint.contentView.bottomAnchor, constant: -11)
            ])
            hintTop = hint.topAnchor.constraint(equalTo: container.topAnchor, constant: 70)
            hintBottom = hint.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -24)
            hintBottom?.isActive = true
        }

        private func page(for direction: ReaderTurnDirection) -> ReaderPage? {
            direction == .next ? parent.nextPage : parent.previousPage
        }

        func update(_ parent: ReaderWebView) {
            guard !invalidated else { return }
            self.parent = parent
            if phase == .entering, parent.contentID == stagedPage?.id {
                promoteStagedPage()
            } else if phase == .idle, !parent.html.isEmpty,
                      loadedHTML != parent.html || loadedContentID != parent.contentID || lastRetryRequest != parent.retryRequest, let web = webView {
                // Full-text extraction and typography changes preserve reading position.
                animator?.stopAnimation(true)
                animator = nil
                preparationTimeout?.cancel()
                discardStagedPage()
                phase = .idle
                direction = nil
                hint.alpha = 0
                DispatchQueue.main.async { [weak self] in self?.parent.onPullActive(false) }
                capturePreviousPage()
                if loadedContentID == parent.contentID {
                    let range = max(1, web.scrollView.contentSize.height - web.scrollView.bounds.height)
                    restoredProgress = min(1, max(0, web.scrollView.contentOffset.y / range))
                } else { restoredProgress = nil }
                web.transform = .identity
                web.alpha = 1
                web.isUserInteractionEnabled = true
                loadedHTML = parent.html
                loadedContentID = parent.contentID
                lastRetryRequest = parent.retryRequest
                resetPosition()
                beginRendering()
                activeNavigation = web.loadHTMLString(parent.html, baseURL: parent.baseURL)
            }
            if (phase == .dragging || phase == .waiting), let direction { stagePage(for: direction) }
            if let request = parent.turnRequest, request.id != lastRequest {
                lastRequest = request.id
                DispatchQueue.main.async { [weak self] in self?.requestTurn(request.direction) }
            }
        }

        private func attach(to web: WKWebView) {
            observation?.invalidate()
            observation = web.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                DispatchQueue.main.async { [weak self, weak scroll] in
                    guard let self, let scroll, scroll === self.webView?.scrollView else { return }
                    self.handleScroll(scroll)
                }
            }
            let pull = UIPanGestureRecognizer(target: self, action: #selector(handlePull(_:)))
            pull.maximumNumberOfTouches = 1
            pull.delegate = self
            web.addGestureRecognizer(pull)
            pullGesture = pull
            // Outward edge pulls own the movement, avoiding a second system bounce.
            // This recognizer immediately fails for regular scrolling and horizontal back.
            web.scrollView.panGestureRecognizer.require(toFail: pull)
            let back = UIPanGestureRecognizer(target: self, action: #selector(handleBack(_:)))
            back.maximumNumberOfTouches = 1
            back.delegate = self
            back.cancelsTouchesInView = false
            web.addGestureRecognizer(back)
            // Right-edge inward pan: a dedicated recognizer keeps the existing
            // horizontal-back and vertical-turn policies untouched.
            let original = UIPanGestureRecognizer(target: self, action: #selector(handleOriginal(_:)))
            original.maximumNumberOfTouches = 1
            original.delegate = self
            original.cancelsTouchesInView = false
            web.addGestureRecognizer(original)
            originalGesture = original
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard phase == .idle, activeNavigation == nil, let web = webView, let container else { return false }
            if gesture === originalGesture {
                guard let url = parent.baseURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
                return ReaderEdgePolicy.isEdgeStart(x: touch.location(in: container).x,
                                                    width: container.bounds.width)
            }
            var view = touch.view
            while let current = view, current !== web {
                if let scroll = current as? UIScrollView, scroll !== web.scrollView,
                   scroll.contentSize.width > scroll.bounds.width + 1,
                   (gesture === pullGesture || scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1) { return false }
                view = current.superview
            }
            if gesture === pullGesture {
                let scroll = web.scrollView
                atTopOnTouch = scroll.contentOffset.y <= 2
                atBottomOnTouch = scroll.contentOffset.y >= max(0, scroll.contentSize.height - scroll.bounds.height) - 4
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard phase == .idle, activeNavigation == nil, let pan = gesture as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: container)
            if gesture === pullGesture {
                direction = ReaderPullPolicy.direction(atTop: atTopOnTouch, atBottom: atBottomOnTouch,
                                                       velocityX: velocity.x, velocityY: velocity.y)
                return direction != nil
            }
            if gesture === originalGesture {
                return ReaderEdgePolicy.isLeftward(velocityX: velocity.x, velocityY: velocity.y)
            }
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.2
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gesture !== pullGesture && other !== pullGesture
        }

        @objc private func handleBack(_ gesture: UIPanGestureRecognizer) {
            let distance = max(0, gesture.translation(in: nil).x)
            switch gesture.state {
            case .changed: parent.onBackDrag(distance)
            case .ended: parent.onBackEnd(distance, gesture.velocity(in: nil).x, false)
            case .cancelled, .failed: parent.onBackEnd(distance, 0, true)
            default: break
            }
        }

        @objc private func handleOriginal(_ gesture: UIPanGestureRecognizer) {
            let distance = ReaderEdgePolicy.distance(translationX: gesture.translation(in: nil).x)
            switch gesture.state {
            case .began, .changed: parent.onOriginalDrag(distance)
            case .ended: parent.onOriginalEnd(distance, gesture.velocity(in: nil).x, false)
            case .cancelled, .failed: parent.onOriginalEnd(distance, 0, true)
            default: break
            }
        }

        @objc private func handlePull(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard let direction else { return }
                beginPull(direction)
                movePull(gesture.translation(in: container).y)
            case .changed:
                guard phase == .dragging else { return }
                if gesture.numberOfTouches > 1 { rebound(); return }
                movePull(gesture.translation(in: container).y)
            case .ended:
                guard phase == .dragging, let direction else { return }
                movePull(gesture.translation(in: container).y)
                if ready, page(for: direction) != nil { waitForPreparedPage() }
                else { rebound() }
            case .cancelled, .failed:
                if phase == .dragging { rebound() }
            default: break
            }
        }

        private func beginPull(_ direction: ReaderTurnDirection) {
            phase = .dragging
            self.direction = direction
            ready = false
            hintTop?.isActive = false
            hintBottom?.isActive = false
            if direction == .previous { hintTop?.isActive = true } else { hintBottom?.isActive = true }
            container?.bringSubviewToFront(hint)
            parent.onPullActive(true)
            stagePage(for: direction)
        }

        private func movePull(_ translationY: CGFloat) {
            guard let direction, let web = webView else { return }
            let distance = ReaderPullPolicy.distance(translationY: translationY, direction: direction)
            let offset = ReaderPullPolicy.offset(distance: distance, direction: direction)
            let wasReady = ready
            ready = ReaderPullPolicy.isReady(distance: distance)
            // Direct UIKit transform: no animation or SwiftUI render on each touch.
            web.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(translationX: 0, y: offset)
            let available = page(for: direction) != nil
            hintLabel.text = ReaderPullPolicy.hint(direction: direction, ready: ready, available: available)
            hintLabel.textColor = ready && available ? UIColor(named: "AccentColor") ?? .systemGreen : .secondaryLabel
            hint.alpha = min(1, abs(offset) / 48)
            if ready && !wasReady { recordProof("pull-ready") }
        }

        private func requestTurn(_ direction: ReaderTurnDirection) {
            guard phase == .idle, activeNavigation == nil else { return }
            beginPull(direction)
            hintLabel.text = ReaderPullPolicy.hint(direction: direction, ready: true, available: page(for: direction) != nil)
            guard page(for: direction) != nil else { hint.alpha = 1; rebound(); return }
            waitForPreparedPage()
        }

        private func stagePage(for direction: ReaderTurnDirection) {
            guard let page = page(for: direction), !page.html.isEmpty, let container else { return }
            if stagedPage == page { return }
            discardStagedPage()
            let stage = makeWebView()
            stage.alpha = 0
            stage.isUserInteractionEnabled = false
            stage.accessibilityElementsHidden = true
            container.insertSubview(stage, at: 0)
            stagingWebView = stage
            stagedPage = page
            stagedReady = false
            stage.loadHTMLString(page.html, baseURL: URL(string: page.url))
        }

        private func waitForPreparedPage() {
            phase = .waiting
            webView?.isUserInteractionEnabled = false
            targetID = direction.flatMap { page(for: $0)?.id }
            if stagedReady { animateOutgoing(); return }
            // Keep the pulled article visible while WebKit finishes laying out the neighbor.
            // A failed/cancelled preparation always returns to the current article.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .waiting else { return }
                self.rebound()
            }
            preparationTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        }

        private func animateOutgoing() {
            guard phase == .waiting, stagedReady, stagedPage?.id == targetID,
                  let web = webView, let direction else { return }
            preparationTimeout?.cancel()
            phase = .leaving
            recordProof("outgoing-start")
            let away = direction.sign * (container?.bounds.height ?? 600) * 0.3
            animate(duration: ReaderPullPolicy.outgoingDuration, outgoing: true) {
                web.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(translationX: 0, y: away)
                web.alpha = 0
                self.hint.alpha = 0
            } completion: { [weak self] in
                guard let self, self.phase == .leaving, let id = self.targetID else { return }
                self.phase = .entering
                guard self.parent.onTurn(direction, id) else { self.rebound(); return }
            }
        }

        private func promoteStagedPage() {
            guard let stage = stagingWebView, let page = stagedPage, let direction else { return }
            previousSnapshot?.removeFromSuperview(); previousSnapshot = nil
            observation?.invalidate()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView?.removeFromSuperview()
            webView = stage
            loadedHTML = page.html
            loadedContentID = page.id
            lastRetryRequest = parent.retryRequest
            let revision = rendering.begin(contentID: page.id)
            rendering.finish(revision)
            reportRendering()
            stagingWebView = nil
            stagedPage = nil
            stagedReady = false
            resetPosition()
            stage.isUserInteractionEnabled = false
            stage.accessibilityElementsHidden = false
            stage.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(translationX: 0, y: -direction.sign * stage.bounds.height * 0.18)
            stage.alpha = 0
            attach(to: stage)
            // Commit the initial position for a frame before entering, like PWA's two RAFs.
            DispatchQueue.main.async { [weak self, weak stage] in
                guard let self, let stage, self.phase == .entering else { return }
                self.parent.onShowHeader(true)
                self.parent.onProgress(0)
                self.recordProof("incoming-start")
                self.animate(duration: ReaderPullPolicy.incomingDuration) {
                    stage.transform = .identity
                    stage.alpha = 1
                } completion: { [weak self] in
                    self?.finishInteraction()
                    self?.recordProof("incoming-finished")
                }
            }
        }

        private func rebound() {
            guard let web = webView else { return }
            preparationTimeout?.cancel()
            phase = .rebounding
            web.isUserInteractionEnabled = false
            recordProof("rebound-start")
            animate(duration: ReaderPullPolicy.reboundDuration) {
                web.transform = .identity
                web.alpha = 1
                self.hint.alpha = 0
            } completion: { [weak self] in
                self?.finishInteraction()
                self?.recordProof("rebound-finished")
            }
        }

        private func animate(duration: TimeInterval, outgoing: Bool = false, changes: @escaping () -> Void, completion: @escaping () -> Void) {
            let timing = UICubicTimingParameters(controlPoint1: outgoing ? CGPoint(x: 0.4, y: 0) : CGPoint(x: 0.2, y: 0.8),
                                                controlPoint2: outgoing ? CGPoint(x: 1, y: 1) : CGPoint(x: 0.2, y: 1))
            let animation = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0.08 : duration, timingParameters: timing)
            animation.addAnimations(changes)
            animation.addCompletion { [weak self] position in
                self?.animator = nil
                if position == .end { completion() }
            }
            animator = animation
            animation.startAnimation()
        }

        private func finishInteraction() {
            phase = .idle
            direction = nil
            targetID = nil
            ready = false
            hint.alpha = 0
            discardStagedPage()
            webView?.isUserInteractionEnabled = true
            if let scroll = webView?.scrollView { lastOffset = scroll.contentOffset.y }
            accumulated = 0
            parent.onPullActive(false)
            // A full-text response may arrive during a pull; apply it after the
            // gesture settles rather than interrupting the page under the finger.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.update(self.parent)
            }
        }

        private func discardStagedPage() {
            stagingWebView?.navigationDelegate = nil
            stagingWebView?.stopLoading()
            stagingWebView?.removeFromSuperview()
            stagingWebView = nil
            stagedPage = nil
            stagedReady = false
        }

        private func resetPosition() {
            lastOffset = 0
            accumulated = 0
            headerShown = true
            lastProgress = -1
        }

        private func capturePreviousPage() {
            // Keep the last visible document if an in-flight replacement is superseded or fails.
            guard previousSnapshot == nil, let web = webView, let container,
                  let snapshot = web.snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = container.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            container.insertSubview(snapshot, belowSubview: hint)
            previousSnapshot = snapshot
        }

        private func revealPage(completion: @escaping () -> Void) {
            let snapshot = previousSnapshot
            previousSnapshot = nil
            guard !UIAccessibility.isReduceMotionEnabled else {
                snapshot?.removeFromSuperview(); webView?.alpha = 1; completion(); return
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: {
                snapshot?.alpha = 0
                self.webView?.alpha = 1
            }) { _ in
                snapshot?.removeFromSuperview()
                completion()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !invalidated else { return }
            if webView === stagingWebView {
                // didFinish can precede WebKit's first layout. Give the prepared
                // document two display frames before replacing the visible page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.034) { [weak self, weak webView] in
                    guard let self, let webView, webView === self.stagingWebView else { return }
                    webView.layoutIfNeeded()
                    self.stagedReady = true
                    if self.phase == .waiting { self.animateOutgoing() }
                }
                return
            }
            guard webView === self.webView, navigation === activeNavigation else { return }
            let revision = rendering.revision
            // didFinish is a network/document event, not proof that the first layout has been painted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.034) { [weak self, weak webView] in
                guard let self, let webView, !self.invalidated, webView === self.webView,
                      navigation === self.activeNavigation, self.rendering.revision == revision else { return }
                webView.layoutIfNeeded()
                self.completeNavigation(webView, revision: revision)
            }
        }

        private func completeNavigation(_ webView: WKWebView, revision: UUID) {
            activeNavigation = nil
            if let progress = restoredProgress {
                let scroll = webView.scrollView
                scroll.setContentOffset(CGPoint(x: 0, y: progress * max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
                restoredProgress = nil
                lastOffset = scroll.contentOffset.y
            }
            #if DEBUG
            if !initialPositionApplied, DesignPreviewData.requestedScreen == "reader-pull-regression" {
                initialPositionApplied = true
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "--reader-position"), index + 1 < args.count {
                    let fraction: CGFloat = args[index + 1] == "bottom" ? 1 : 0.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak webView] in
                        guard let self, let webView, webView === self.webView else { return }
                        let scroll = webView.scrollView
                        scroll.contentOffset.y = max(0, scroll.contentSize.height - scroll.bounds.height) * fraction
                        self.handleScroll(scroll)
                        self.recordProof("positioned")
                    }
                }
            }
            #endif
            handleScroll(webView.scrollView)
            revealPage { [weak self] in
                guard let self, !self.invalidated, self.rendering.finish(revision) else { return }
                self.reportRendering()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, navigation) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, navigation) }

        private func navigationFailed(_ web: WKWebView, _ navigation: WKNavigation?) {
            guard !invalidated else { return }
            if web === stagingWebView {
                discardStagedPage()
                if phase == .waiting { rebound() }
            } else if web === webView, navigation === activeNavigation {
                activeNavigation = nil
                web.alpha = 1
                web.isUserInteractionEnabled = false
                // Leave the previous snapshot visible until an explicit retry succeeds.
                rendering.finish(rendering.revision, failure: "正文显示未完成")
                reportRendering()
            }
        }

        private func handleScroll(_ scroll: UIScrollView) {
            guard activeNavigation == nil, phase == .idle else { return }
            let offset = scroll.contentOffset.y
            let range = max(1, scroll.contentSize.height - scroll.bounds.height)
            let progress = Int(min(1, max(0, offset / range)) * 100)
            if progress != lastProgress { lastProgress = progress; parent.onProgress(Double(progress) / 100) }
            let delta = offset - lastOffset
            lastOffset = offset
            if offset <= 2 {
                accumulated = 0
                if !headerShown { headerShown = true; parent.onShowHeader(true) }
                return
            }
            accumulated += delta
            if accumulated > 40 {
                accumulated = 0
                if headerShown { headerShown = false; parent.onShowHeader(false) }
            } else if accumulated < -40 {
                accumulated = 0
                if !headerShown { headerShown = true; parent.onShowHeader(true) }
            }
        }

        func invalidate() {
            invalidated = true
            rendering.invalidate()
            previousSnapshot?.removeFromSuperview(); previousSnapshot = nil
            animator?.stopAnimation(true)
            animator = nil
            preparationTimeout?.cancel()
            observation?.invalidate()
            discardStagedPage()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView?.stopLoading()
        }

        private func recordProof(_ event: String) {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--reader-proof"), index + 1 < args.count,
                  let web = webView else { return }
            let details: [String: Any] = ["event": event, "phase": phase.rawValue, "id": loadedContentID,
                                          "offset": Double(web.transform.ty), "scroll": Double(web.scrollView.contentOffset.y),
                                          "range": Double(max(0, web.scrollView.contentSize.height - web.scrollView.bounds.height)),
                                          "time": ProcessInfo.processInfo.systemUptime]
            proofEvents.append(details)
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ReaderPullProof").appendingPathComponent(args[index + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: proofEvents, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("events.json"))
            }
            let name = "\(proofEvents.count)-\(event).png"
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.container?.window else { return }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try? image.pngData()?.write(to: directory.appendingPathComponent(name))
            }
            #endif
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.scheme == "weidu-reader" {
                    parent.onReaderAction(url)
                    decisionHandler(.cancel)
                    return
                }
                if let scheme = url.scheme?.lowercased() {
                    if scheme == "http" || scheme == "https" {
                        parent.onOpenExternal(url)
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "http" || scheme == "https" {
                    parent.onOpenExternal(url)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }
    }
}
