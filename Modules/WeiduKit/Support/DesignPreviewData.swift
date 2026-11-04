#if DEBUG
import Foundation

// Isolated simulator fixtures. Release builds contain neither this data nor this launch route.
enum DesignPreviewData {
    static var requestedScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--design-preview"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static let feeds: [Feed] = [
        feed("room", "一间书房", "room.example.com", 3),
        feed("design", "设计札记", "design.example.com", 2),
        feed("nature", "山野来信", "nature.example.com", 1),
        feed("tech", "技术随笔", "tech.example.com", 4)
    ]

    static var entries: [Entry] {
        let titles = ["把注意力还给真正喜欢的事", "好的设计，是让日常变得轻一点", "走进山里，也走回自己的生活", "那些值得慢慢读完的长文章", "在信息很多的时候，如何保持好奇心", "一杯咖啡与一个没有安排的下午"]
        let summaries = ["在忙碌的日程里，留出一点不被打扰的时间，重新发现阅读的乐趣。", "界面最好的状态，是让人自然地找到想做的事，然后安心地继续。", "沿着河流往前走，风吹过树林，有些答案就在安静的路上。"]
        return titles.enumerated().map { index, title in
            let feed = feeds[index % feeds.count]
            let date = Date().addingTimeInterval(-Double(index < 4 ? index * 1800 : 86400 + index * 1800))
            return Entry(id: "preview-\(index)", feedID: feed.id, feedTitle: feed.title,
                         title: title, url: "https://example.com/article/\(index)", author: "",
                         summary: summaries[index % summaries.count],
                         contentHTML: "<p>我们每天都在接收新的信息，却很少停下来想一想，哪些文字真的值得留下。</p><p>阅读可以是一件很简单的事：找到喜欢的声音，留出一点时间，然后专心地读下去。</p><h2>留一点空白</h2><p>不急着读完所有文章，也不必追赶每一次更新。把注意力还给自己，让好奇心带路。</p><blockquote>好的阅读体验，让界面退后，让文字走到眼前。</blockquote><p>在安静的间隙里，我们重新看见日常，也重新看见自己。</p>",
                         fulltextHTML: nil, imageURL: "", publishedAt: date, fetchedAt: date,
                         isRead: index == 3, isStarred: index == 1 || index == 4,
                         opened: index == 3, sortTime: date.timeIntervalSince1970)
        }
    }

    static var scrollRegressionEntries: [Entry] {
        let sample = entries[0]
        return (0..<18).map { index in
            var entry = sample
            entry.id = "preview-\(index)"
            entry.title = "滚动回归文章 \(index + 1)"
            entry.publishedAt = Date().addingTimeInterval(-Double(index * 60))
            entry.sortTime = entry.date.timeIntervalSince1970
            return entry
        }
    }

    private static func feed(_ id: String, _ title: String, _ host: String, _ count: Int) -> Feed {
        Feed(id: id, url: "https://\(host)/feed", title: title, siteURL: "https://\(host)",
             iconURL: "", category: "", sort: 0, addedAt: Date(), lastFetchAt: Date(),
             lastError: nil, etag: "", lastModified: "", unreadCount: count)
    }
}
#endif
