import Foundation
import SwiftUI
import CryptoKit

@MainActor
public final class WeiduNavigation: ObservableObject {
    @Published var article: String?
    var feed: String?
    @Published var revision = UUID()
    @Published var selectedFeeds: [String] = []
    var selectionPending = false
    var closeCurrent = false
    private var selectionURL: URL?
    public init() { }
    public var feedSelection: [Int] { selectedFeeds.compactMap(Int.init) }
    public func openArticle(_ id: Int) { article = String(id); revision = UUID() }
    public func openFeed(_ id: Int) { feed = String(id); article = nil; revision = UUID() }
    public func refresh() { revision = UUID() }
    public func closeArticleAndRefresh() { closeCurrent = true; article = nil; revision = UUID() }
    public func selectFeeds(_ ids: [Int]) {
        var seen: Set<Int> = []
        selectedFeeds = ids.filter { $0 > 0 && seen.insert($0).inserted }.prefix(100).map(String.init)
        if let selectionURL, let data = try? JSONEncoder().encode(selectedFeeds) { try? data.write(to: selectionURL, options: [.atomic, .completeFileProtection]) }
        selectionPending = true; article = nil; revision = UUID()
    }
    func configure(folder: URL) {
        let url = folder.appendingPathComponent("selected-feeds.json")
        guard selectionURL != url else { return }
        selectionURL = url
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        if let data = try? Data(contentsOf: url), let ids = try? JSONDecoder().decode([String].self, from: data) { selectedFeeds = Array(ids.filter { Int($0).map { $0 > 0 } ?? false }.prefix(100)) }
        else { selectedFeeds = [] }
    }
}

public struct WeiduWorkspaceFailure: LocalizedError {
    public let status: Int
    public let message: String
    public init(status: Int, message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}

@MainActor
public struct WeiduWorkspaceConnection {
    public let scope: String
    let navigation: WeiduNavigation
    let transport: (String, String, Data?) async throws -> Data
    let articleTools: (Int, String, String) -> AnyView
    public init(scope: String, navigation: WeiduNavigation,
                transport: @escaping (String, String, Data?) async throws -> Data,
                articleTools: @escaping (Int, String, String) -> AnyView) {
        self.scope = scope; self.navigation = navigation; self.transport = transport; self.articleTools = articleTools
        navigation.configure(folder: folder)
    }
    var folder: URL {
        let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Weidu/Cloud/\(hash)", isDirectory: true)
    }
    func request(_ path: String, method: String = "GET", payload: CloudValue? = nil) async throws -> CloudValue {
        let data = try await transport(path, method, try payload.map { try JSONEncoder().encode($0) })
        return try JSONDecoder().decode(CloudValue.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }
}

enum CloudValue: Codable, Equatable {
    case object([String: CloudValue]), array([CloudValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: CloudValue].self) { self = .object(v) }
        else { self = .array(try c.decode([CloudValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let x): try c.encode(x); case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x); case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x); case .null: try c.encodeNil() }
    }
    subscript(_ k: String) -> Self {
        get { object[k] ?? .null }
        set { var o = object; o[k] = newValue; self = .object(o) }
    }
    var object: [String: Self] { if case .object(let x) = self { return x }; return [:] }
    var array: [Self] { if case .array(let x) = self { return x }; return [] }
    var text: String { switch self { case .string(let x): return x; case .number(let x): return String(format: "%.15g", x); default: return "" } }
    var int: Int { guard let d = Double(text), d.isFinite, d >= 0, d < Double(Int.max) else { return 0 }; return Int(d) }
    var flag: Bool { if case .bool(let x) = self { return x }; return false }
    var date: Date? { Format.parseISODate(text) }
}

struct CloudOperation: Codable {
    let id: String
    let revision: UUID
    let path: String
    let body: CloudValue
}

/// State writes survive a restart; acknowledgements remove only the revision actually sent.
@MainActor
final class CloudJournal {
    private let url: URL
    private(set) var loadFailure: String?
    private(set) var operations: [CloudOperation] = []
    init(folder: URL) {
        url = folder.appendingPathComponent("pending-states.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { operations = try JSONDecoder().decode([CloudOperation].self, from: Data(contentsOf: url)) }
            catch { loadFailure = "离线修改队列无法读取，已保留原文件，请重新打开阅读库后重试" }
        }
    }
    func enqueue(id: String, path: String, body: CloudValue) throws {
        try enqueue([CloudOperation(id: id, revision: UUID(), path: path, body: body)])
    }
    func enqueue(_ changes: [CloudOperation]) throws {
        guard !changes.isEmpty else { return }
        var replacement = operations
        var positions = Dictionary(replacement.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, new in new })
        for change in changes {
            let position = positions[change.id]
            var merged = position.map { replacement[$0].body.object } ?? [:]
            merged.merge(change.body.object) { _, new in new }
            let next = CloudOperation(id: change.id, revision: change.revision, path: change.path, body: .object(merged))
            if let position { replacement[position] = next }
            else { positions[change.id] = replacement.count; replacement.append(next) }
        }
        try persist(replacement); operations = replacement
    }
    func acknowledge(_ operation: CloudOperation) throws {
        try acknowledge([operation])
    }
    func acknowledge(_ sent: [CloudOperation]) throws {
        let revisions = Set(sent.map(\.revision))
        let next = operations.filter { !revisions.contains($0.revision) }
        try persist(next); operations = next
    }
    func state(_ id: String) -> CloudValue? { operations.first { $0.id == "entry:\(id)" }?.body }
    private func persist(_ values: [CloudOperation]) throws {
        if let loadFailure { throw WeiduError.network(loadFailure) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
