import SwiftUI

struct FeedReadingSettings: View {
    let feed: Feed
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(feed.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("关闭订阅设置")
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("自动抓取原文").font(.system(size: 15, weight: .medium))
                    Text("打开文章时自动获取全文，适合只提供摘要的订阅。已有缓存时直接阅读。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3).lineSpacing(3)
                }
                Spacer(minLength: 0)
                Toggle("自动抓取原文", isOn: Binding(
                    get: { store.feeds.first(where: { $0.id == feed.id })?.autoFulltext ?? feed.autoFulltext },
                    set: { store.setAutoFulltext(feed, enabled: $0) }
                ))
                .labelsHidden()
                .accessibilityLabel("自动抓取原文")
                .accessibilityIdentifier("feed-auto-fulltext")
            }
            Text("更改即时保存").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Spacer(minLength: 0)
        }
        .padding(24)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .background(Theme.background.ignoresSafeArea())
    }
}
