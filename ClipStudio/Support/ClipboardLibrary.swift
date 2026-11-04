import Foundation
import CryptoKit

// Only record references are persisted. Clipboard plaintext and credentials never enter UserDefaults.
struct ClipboardContext: Equatable {
    let server: String
    let username: String
    let keyID: String?
    let key: Data

    init(_ account: Account) {
        server = account.base.absoluteString
        username = account.username
        keyID = account.keyInfo.key_id
        key = account.key
    }
}

struct ClipboardFavorites {
    let defaults: UserDefaults

    private func storageKey(_ account: Account) -> String {
        let identity = [account.base.absoluteString, account.username, account.keyInfo.key_id ?? ""]
        let encoded = (try? JSONEncoder().encode(identity)) ?? Data()
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return "clipboard.favorites.v1." + digest
    }

    static func reference(_ row: ClipRow) -> String { "\(row.id):\(row.remote.cid)" }

    func load(for account: Account) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey(account)) ?? [])
    }

    func save(_ references: Set<String>, for account: Account) {
        defaults.set(references.sorted(), forKey: storageKey(account))
    }

    func clear(for account: Account) { defaults.removeObject(forKey: storageKey(account)) }
}

enum ClipboardSource: String, CaseIterable, Identifiable {
    case all = "所有来源", computer = "电脑", mobile = "手机和网页"
    var id: String { rawValue }
    func includes(_ row: ClipRow) -> Bool {
        switch self {
        case .all: return true
        case .computer: return row.remote.source == "windows"
        case .mobile: return row.remote.source != "windows"
        }
    }
}

enum ClipboardKind: String, CaseIterable, Identifiable {
    case all = "全部类型", text = "文字", image = "图片"
    var id: String { rawValue }
    var symbol: String? {
        switch self {
        case .all: return nil
        case .text: return "textformat"
        case .image: return "photo"
        }
    }
    func includes(_ row: ClipRow) -> Bool {
        self == .all || row.remote.kind == (self == .image ? "image" : "text")
    }
}

struct ClipboardFilter {
    var favoritesOnly = false
    var source: ClipboardSource = .all
    var kind: ClipboardKind = .all
    var query = ""

    func apply(to rows: [ClipRow], favorites: Set<String>) -> [ClipRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            (!favoritesOnly || favorites.contains(ClipboardFavorites.reference(row))) &&
            source.includes(row) && kind.includes(row) &&
            (query.isEmpty || row.title.localizedCaseInsensitiveContains(query) || row.device.localizedCaseInsensitiveContains(query))
        }
    }

    static func selected(_ references: Set<String>, in rows: [ClipRow]) -> [ClipRow] {
        rows.filter { references.contains(ClipboardFavorites.reference($0)) }
    }

    // The refreshed pages are authoritative over their covered range. Older loaded pages stay in place.
    static func merge(_ refreshed: [ClipRow], with loaded: [ClipRow], hasMore: Bool) -> [ClipRow] {
        guard hasMore, let oldest = refreshed.map(\.id).min() else { return refreshed }
        var seen = Set<Int>()
        return (refreshed + loaded.filter { $0.id < oldest })
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id > $1.id }
    }
}

struct ClipboardContent {
    let row: ClipRow
    let context: ClipboardContext
    let data: Data
}

struct PendingClipboardDeletion: Identifiable {
    let id = UUID()
    let rows: [ClipRow]
    let context: ClipboardContext
    var committing = false
    var references: Set<String> { Set(rows.map(ClipboardFavorites.reference)) }
}

struct ClipboardDeletionFailure {
    let rows: [ClipRow]
    let message: String
}
