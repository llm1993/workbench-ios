import Foundation

struct CacheUsage: Equatable {
    var count: Int
    var bytes: Int64
    static let zero = CacheUsage(count: 0, bytes: 0)
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum CacheKind: Equatable { case articles, images, all }

enum CachePolicy {
    static func isDue(days: Int, since: Date, now: Date) -> Bool {
        days > 0 && now.timeIntervalSince(since) >= Double(days) * 86400
    }
}
