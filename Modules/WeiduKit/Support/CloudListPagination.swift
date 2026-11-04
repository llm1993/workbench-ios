import Foundation

// The API uses offsets into a live filtered set. Count only confirmed server
// removals, not local edits which may still be waiting in the offline journal.
struct CloudListPagination {
    private struct State {
        var read = false
        var starred = false
        var readRevision = -1
        var starRevision = -1
        var deleted = false
    }
    private var states: [String: State] = [:]
    private var loaded: Set<String> = []
    private(set) var receivedCount = 0
    private(set) var hasLoadedPage = false

    func offset(unreadOnly: Bool, starredOnly: Bool) -> Int {
        let removed = loaded.reduce(0) { count, id in
            guard let state = states[id] else { return count }
            return count + (state.deleted || (unreadOnly && state.read) || (starredOnly && !state.starred) ? 1 : 0)
        }
        return max(0, receivedCount - removed)
    }

    mutating func record(_ rows: [CloudValue], requestRevision: Int) {
        hasLoadedPage = true
        receivedCount += rows.count
        for row in rows {
            let id = Database.cloudID(row)
            loaded.insert(id)
            var state = states[id] ?? State()
            // An ACK may arrive while this GET is in flight. Its newer fields
            // remain authoritative even when the response contains old flags.
            if state.readRevision <= requestRevision { state.read = row["is_read"].flag }
            if state.starRevision <= requestRevision { state.starred = row["is_starred"].flag }
            states[id] = state
        }
    }

    mutating func acknowledge(id: String, body: CloudValue, revision: Int, deleted: Bool = false) {
        var state = states[id] ?? State()
        if body["read"] != .null { state.read = body["read"].flag; state.readRevision = revision }
        if body["starred"] != .null { state.starred = body["starred"].flag; state.starRevision = revision }
        state.deleted = deleted
        states[id] = state
    }
}

struct ReaderTabTapPolicy {
    private var last: (tab: AppTab, date: Date)?
    mutating func tap(_ tab: AppTab, selected: AppTab, now: Date = Date()) -> Bool {
        defer { last = (tab, now) }
        guard tab == selected, let last, last.tab == tab else { return false }
        return (0..<0.45).contains(now.timeIntervalSince(last.date))
    }
}
