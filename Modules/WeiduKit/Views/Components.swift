import SwiftUI
import UIKit

struct AppHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var back: (() -> Void)? = nil
    let trailing: () -> Trailing

    init(title: String, subtitle: String, back: (() -> Void)? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.back = back
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5).padding(.horizontal, 20)
        }
    }
}

struct HeaderIconButton: View {
    let systemName: String
    var spinning = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if spinning {
                    ProgressView().controlSize(.small).tint(Theme.text2)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(systemName == "magnifyingglass" ? "搜索" : systemName == "arrow.clockwise" ? "刷新" : systemName == "plus" ? "添加订阅" : systemName)
    }
}

struct FilterChip: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Menu {
            Picker("显示", selection: $store.settings.listView) {
                ForEach(UnreadFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            Divider()
            Button {
                store.markAllRead()
            } label: {
                Label("全部标为已读", systemImage: "checkmark.circle")
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.settings.listView.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(Theme.surface2)
            .clipShape(Capsule())
        }
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface2 : Color.clear)
            .contentShape(Rectangle())
    }
}

enum FeedPalette {
    private static let colors: [Color] = [
        Color(hex: 0xD98D5F), Color(hex: 0x8FAE77), Color(hex: 0x7C9FC4),
        Color(hex: 0xC08BA4), Color(hex: 0xB3A06A), Color(hex: 0x7FB2AC),
        Color(hex: 0xB08B6A), Color(hex: 0x9C93C4)
    ]

    static func color(for id: String) -> Color {
        if let numeric = Int(id), numeric > 0 {
            // Match PWA hsl((feedId * 47) % 360, 42%, 55%).
            return Color(hue: Double((numeric % 360 * 47) % 360) / 360, saturation: 2 * (1 - 0.55 / 0.739), brightness: 0.739)
        }
        var value = 0
        for scalar in id.unicodeScalars {
            value = (value &* 31 &+ Int(scalar.value)) & 0x7FFFFFFF
        }
        return colors[value % colors.count]
    }
}

struct ArticleRowSurface: ViewModifier {
    let style: ArticleListStyle
    let density: ListDensity

    @ViewBuilder func body(content: Content) -> some View {
        switch style {
        case .card:
            content
                .padding(.horizontal, 16)
                .padding(.top, density.verticalPadding)
                .padding(.bottom, density.verticalPadding + (density == .expansive ? 2 : 0))
                .panelSurface(radius: 18)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
        case .plain:
            content
                .padding(.horizontal, 16)
                .padding(.top, density.verticalPadding)
                .padding(.bottom, density.verticalPadding + (density == .expansive ? 2 : 0))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct EntryRow: View, Equatable {
    let entry: Entry
    let settings: AppSettings
    var previewImage = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(FeedPalette.color(for: entry.feedID))
                        .frame(width: 6, height: 6)
                    Text(entry.feedTitle.isEmpty ? "未命名" : entry.feedTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
                .padding(.bottom, 4)

                Text(entry.displayTitle)
                    .font(.system(size: settings.listTitleSize, weight: entry.isRead ? .regular : .medium))
                    .foregroundStyle(entry.isRead ? Theme.text2 : Theme.text)
                    .lineLimit(nil)
                    .lineSpacing(settings.density == .expansive ? 2 : 3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.listShowsSummary, !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.system(size: CGFloat(settings.listFontSize) - 2.5))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(2)
                        .lineSpacing(4)
                        .padding(.top, 5)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("entry-summary-\(entry.id)")
                }
                HStack(spacing: 8) {
                    Text(Format.relative(entry.date)).font(.system(size: 12)).foregroundStyle(Theme.text3)
                    if entry.isStarred { Image(systemName: "star.fill").font(.system(size: 13)).foregroundStyle(Theme.star) }
                }.padding(.top, 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if settings.listShowsImages, previewImage || !entry.imageURL.isEmpty {
                Group {
                    if previewImage { Theme.surface2.overlay(Image(systemName: "photo").foregroundStyle(Theme.text3)) }
                    else { CachedArticleImage(url: entry.imageURL, referer: entry.url, pointSize: settings.density.thumbnailSize) }
                }
                .frame(width: settings.density.thumbnailSize, height: settings.density.thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityIdentifier("entry-image-\(entry.id)")
            }
        }
        .modifier(ArticleRowSurface(style: settings.listStyle, density: settings.density))
        .contentShape(Rectangle())
    }
}

struct FeedRow: View {
    let feed: Feed
    var showsChevron = true

    var body: some View {
        HStack(spacing: 11) {
            Text(String(feed.title.prefix(1)).uppercased())
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(FeedPalette.color(for: feed.id))
                .frame(width: 38, height: 38)
                .background(FeedPalette.color(for: feed.id).opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(feed.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if feed.autoFulltext {
                    Text("自动全文").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                }
                HStack(spacing: 5) {
                    Text(feed.host)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                    if feed.lastError != nil {
                        Text("· 更新失败")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0xC05B4E))
                    }
                }
            }
            Spacer(minLength: 8)
            if feed.unreadCount > 0 {
                Text("\(feed.unreadCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.14))
                    .clipShape(Capsule())
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct BannerView: View {
    let banner: Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(banner.isError ? Color(hex: 0xF0A58F) : Color(hex: 0xA8D8BE))
            Text(banner.text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color(hex: 0xF3F5F1))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color.dynamic(light: 0x252E28, dark: 0x2F3833),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 18, y: 6)
        .padding(.horizontal, 16)
    }
}

struct EmptyAction {
    let title: String
    let action: () -> Void
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var primary: EmptyAction? = nil
    var secondary: EmptyAction? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.text3)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 36)
            HStack(spacing: 10) {
                if let primary {
                    Button(action: primary.action) {
                        Text(primary.title)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let secondary {
                    Button(action: secondary.action) {
                        Text(secondary.title)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.text2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(Capsule().stroke(Theme.lineStrong, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum ExportedFile {
    static func writeOPML(_ text: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("未读订阅.opml")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
