import Foundation

enum Format {
    private static let dateFormats = ReaderDateFormats()
    static func relative(_ date: Date) -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400, Calendar.current.isDate(date, inSameDayAs: now) {
            return "\(Int(seconds / 3600)) 小时前"
        }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) {
            return "昨天 " + string(date, format: "HH:mm")
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return string(date, format: "M月d日")
        }
        return string(date, format: "yyyy年M月d日")
    }

    static func dayTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return string(date, format: "HH:mm")
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 " + string(date, format: "HH:mm")
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return string(date, format: "M月d日 HH:mm")
        }
        return string(date, format: "yyyy年M月d日")
    }

    static func string(_ date: Date, format: String) -> String {
        dateFormats.string(date, format: format)
    }

    static func parseISODate(_ value: String) -> Date? { dateFormats.parse(value) }

    static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func host(_ value: String) -> String {
        guard let host = URL(string: value)?.host else { return value }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func normalizedURL(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

// A loaded prefix contains the same timestamps on every pagination request.
// Keep formatters and parsed dates reusable rather than constructing them for
// each row. Calls from feed/image workers are serialized by this small cache.
private final class ReaderDateFormats {
    private let lock = NSLock()
    private var output: [String: DateFormatter] = [:]
    private let dates = NSCache<NSString, NSDate>()
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()

    init() {
        dates.countLimit = 2048
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        whole.formatOptions = [.withInternetDateTime]
    }

    func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = dates.object(forKey: value as NSString) { return cached as Date }
        let result = fractional.date(from: value) ?? whole.date(from: value)
        if let result { dates.setObject(result as NSDate, forKey: value as NSString) }
        return result
    }

    func string(_ date: Date, format: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = output[format] { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = format
            output[format] = formatter
        }
        return formatter.string(from: date)
    }
}
