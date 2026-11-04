import Foundation

// Build calendar groups only when the rows change, not when navigation chrome,
// sync counts or a refresh indicator publishes another Store update.
struct ArticleListSnapshot {
    let ids: [String]
    let groups: [ArticleDayGroup]
    let unreadCount: Int

    init(entries: [Entry], calendar: Calendar = .current) {
        var ids: [String] = [], groups: [ArticleDayGroup] = []
        var unread = 0
        ids.reserveCapacity(entries.count)
        for entry in entries {
            ids.append(entry.id)
            if !entry.isRead { unread += 1 }
            let day = calendar.startOfDay(for: entry.date)
            if groups.last?.day == day { groups[groups.count - 1].entries.append(entry) }
            else { groups.append(ArticleDayGroup(day: day, entries: [entry])) }
        }
        self.ids = ids; self.groups = groups; self.unreadCount = unread
    }
}

struct ArticleDayGroup: Identifiable, Equatable {
    // Server ordering puts undated articles last. Their fetched day may repeat
    // a day from an earlier group, so the date alone is not a unique row ID.
    var id: String { "day-" + (entries.first?.id ?? "") }
    let day: Date
    var entries: [Entry]
    var title: String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        let parts = Calendar.current.dateComponents([.month, .day], from: day)
        return "\(parts.month ?? 1) 月 \(parts.day ?? 1) 日"
    }
}
