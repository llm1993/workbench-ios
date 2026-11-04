import SwiftUI
import AVKit

struct ArticleVideoPlayer: View {
    let presentation: VideoPresentation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback: ArticlePlayback

    init(presentation: VideoPresentation) {
        self.presentation = presentation
        _playback = StateObject(wrappedValue: ArticlePlayback(url: presentation.url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            NativeArticlePlayer(player: playback.player).ignoresSafeArea()
            if playback.state == "loading" {
                VStack { Spacer(); ProgressView("正在加载视频…").tint(.white).foregroundStyle(.white); Spacer() }
                    .frame(maxWidth: .infinity)
            }
            if playback.state == "failed" {
                VStack(spacing: 18) {
                    Spacer()
                    Text("暂时无法播放此媒体").foregroundStyle(.white)
                    Button("在浏览器打开") { UIApplication.shared.open(presentation.url) }.tint(.white)
                    Spacer()
                }.frame(maxWidth: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("关闭视频")
            .padding(12)
            #if DEBUG
            Text(playback.state).font(.system(size: 1)).foregroundStyle(.clear)
                .accessibilityIdentifier("video-playback-state").allowsHitTesting(false)
            #endif
        }
        .onAppear { playback.player.play() }
        .onDisappear { playback.stop() }
    }
}

private struct NativeArticlePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

@MainActor private final class ArticlePlayback: ObservableObject {
    let player: AVPlayer
    @Published var state = "loading"
    private var timeObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?

    init(url: URL) {
        player = AVPlayer(url: url)
        timeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard self?.state != "failed" else { return }
                switch player.timeControlStatus {
                case .playing: self?.state = "playing"
                case .waitingToPlayAtSpecifiedRate: self?.state = "loading"
                default: self?.state = "paused"
                }
            }
        }
        itemObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { DispatchQueue.main.async { self?.state = "failed" } }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        timeObservation?.invalidate()
        itemObservation?.invalidate()
    }
}
