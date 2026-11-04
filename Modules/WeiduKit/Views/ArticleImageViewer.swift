import SwiftUI
import UIKit
import ImageIO

struct ArticleImageViewer: View {
    let presentation: ImagePresentation
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retry = UUID()

    init(presentation: ImagePresentation) {
        self.presentation = presentation
        _index = State(initialValue: presentation.index)
    }

    private var item: ArticleImage { presentation.images[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableArticleImage(image: image, identity: item.id, alt: item.alt,
                                 close: { dismiss() }, step: step)
                .ignoresSafeArea()
            if image == nil && !failed { ProgressView().tint(.white) }
            if failed && image == nil {
                VStack(spacing: 18) {
                    Text("图片加载失败").foregroundStyle(.white)
                    Button("重试") { retry = UUID() }.tint(.white)
                    if let url = URL(string: item.url) {
                        Button("打开原图") { UIApplication.shared.open(url) }.tint(.white)
                    }
                }
            }
            VStack {
                HStack {
                    Text("\(index + 1) / \(presentation.images.count)")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                            .background(.black.opacity(0.5), in: Circle())
                    }.accessibilityLabel("关闭图片")
                }
                Spacer()
                if presentation.images.count > 1 {
                    HStack {
                        Button { step(-1) } label: {
                            Image(systemName: "chevron.left").frame(width: 48, height: 48).background(.black.opacity(0.5), in: Circle())
                        }
                            .disabled(index == 0).accessibilityLabel("上一张图片")
                        Spacer()
                        Text("双指缩放 · 双击放大").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.5), in: Capsule())
                        Spacer()
                        Button { step(1) } label: {
                            Image(systemName: "chevron.right").frame(width: 48, height: 48).background(.black.opacity(0.5), in: Circle())
                        }
                            .disabled(index == presentation.images.count - 1).accessibilityLabel("下一张图片")
                    }
                }
            }
            .padding(.horizontal, 16).foregroundStyle(.white)
        }
        .statusBarHidden()
        .task(id: item.id + retry.uuidString) {
            let current = item
            image = nil
            failed = false
            do {
                let cached = try await ImageCache.shared.image(url: current.url, referer: presentation.referer)
                guard !Task.isCancelled else { return }
                image = Self.decode(cached.data)
                failed = image == nil
                if !current.largeURL.isEmpty, current.largeURL != current.url,
                   let large = try? await ImageCache.shared.image(url: current.largeURL, referer: presentation.referer), !Task.isCancelled,
                   let decoded = Self.decode(large.data) { image = decoded }
            } catch { if !Task.isCancelled { failed = true } }
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if presentation.images.indices.contains(next) { index = next }
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct ZoomableArticleImage: UIViewRepresentable {
    let image: UIImage?
    let identity: String
    let alt: String
    let close: () -> Void
    let step: (Int) -> Void

    func makeUIView(context: Context) -> ImageZoomScrollView { ImageZoomScrollView() }
    func updateUIView(_ view: ImageZoomScrollView, context: Context) {
        view.close = close
        view.step = step
        view.setImage(image, identity: identity, alt: alt)
    }
}

private final class ImageZoomScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let picture = UIImageView()
    private var identity = ""
    private var lastSize = CGSize.zero
    var close: (() -> Void)?
    var step: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        accessibilityIdentifier = "reader-image-zoom"
        accessibilityValue = "1.00"
        picture.contentMode = .scaleAspectFit
        picture.isAccessibilityElement = true
        picture.accessibilityIdentifier = "reader-image"
        addSubview(picture)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap))
        single.require(toFail: double)
        addGestureRecognizer(single)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
            let gesture = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:)))
            gesture.direction = direction
            gesture.delegate = self
            addGestureRecognizer(gesture)
            panGestureRecognizer.require(toFail: gesture)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage?, identity: String, alt: String) {
        let changed = self.identity != identity
        if !changed, zoomScale > 1.01 { return }
        guard changed || picture.image !== image else { return }
        self.identity = identity
        setZoomScale(1, animated: false)
        picture.image = image
        picture.accessibilityLabel = alt.isEmpty ? "文章图片" : alt
        fitImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            setZoomScale(1, animated: false)
            fitImage()
        }
        centerImage()
    }

    private func fitImage() {
        guard let image = picture.image, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        picture.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerImage()
    }

    private func centerImage() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage(); accessibilityValue = String(format: "%.2f", zoomScale) }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UISwipeGestureRecognizer { return zoomScale <= 1.01 }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    @objc private func singleTap() { close?() }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 { setZoomScale(1, animated: true); return }
        let point = gesture.location(in: picture)
        let rect = CGRect(x: point.x - bounds.width / 5, y: point.y - bounds.height / 5, width: bounds.width / 2.5, height: bounds.height / 2.5)
        zoom(to: rect, animated: true)
    }
    @objc private func swipe(_ gesture: UISwipeGestureRecognizer) {
        if gesture.direction == .left { step?(1) }
        else if gesture.direction == .right { step?(-1) }
        else { close?() }
    }
}
