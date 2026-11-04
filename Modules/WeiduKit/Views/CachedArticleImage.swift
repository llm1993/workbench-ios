import SwiftUI
import UIKit

struct CachedArticleImage: View {
    let url: String
    let referer: String
    var pointSize: CGFloat = 74
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                Theme.surface2.overlay(Image(systemName: "photo").font(.system(size: 16)).foregroundStyle(Theme.text3))
            }
        }
        .task(id: "\(displayScale)|\(pointSize)|\(url)|\(referer)") {
            image = nil
            if let thumbnail = try? await ImageCache.shared.thumbnail(url: url, referer: referer, pixelSize: Int(pointSize * displayScale)), !Task.isCancelled {
                image = thumbnail
            }
        }
    }
}
