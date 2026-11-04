import Foundation
import SwiftUI

struct AssetsSession: Equatable {
    let server: URL
    let token: String

    init(_ api: ClipAPI) {
        server = api.base
        token = api.token
    }
}

enum AssetsTab: String, CaseIterable, Identifiable, Hashable {
    case overview, inventory, wishes, review

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "总览"
        case .inventory: return "家底"
        case .wishes: return "心愿"
        case .review: return "复盘"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "house"
        case .inventory: return "shippingbox"
        case .wishes: return "heart"
        case .review: return "chart.xyaxis.line"
        }
    }
}

enum AssetsSort: String, CaseIterable, Identifiable {
    case dailyCost = "daily_cost", residual, holdDays = "hold_days", purchaseDate = "purchase_date", name, bookCost = "value"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dailyCost: return "日均成本"
        case .residual: return "当前估值"
        case .holdDays: return "持有天数"
        case .purchaseDate: return "购入日期"
        case .name: return "名称"
        case .bookCost: return "账面投入"
        }
    }
}

struct AssetsFilter: Equatable {
    var query = ""
    var status = ""
    var category = ""
    var tag = ""
    var sort: AssetsSort = .dailyCost

    var hasRestrictions: Bool { !query.isEmpty || !status.isEmpty || !category.isEmpty || !tag.isEmpty }
    var path: String {
        ClipAPI.path("/api/assets", query: [
            "q": query.trimmingCharacters(in: .whitespacesAndNewlines), "status": status,
            "category_id": category, "tag": tag.trimmingCharacters(in: .whitespacesAndNewlines),
            "sort": sort == .residual ? "daily_cost" : sort.rawValue,
            "order": sort == .name ? "asc" : "desc"
        ].filter { !$0.value.isEmpty })
    }
    func rows(_ document: JSONValue) -> [JSONValue] {
        guard sort == .residual else { return document["items"].array }
        func value(_ row: JSONValue) -> Decimal? {
            let raw = row["metrics"]["residual_value"]
            guard raw.numeric != nil, let value = Decimal(string: raw.text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
            return value
        }
        return document["items"].array.sorted { lhs, rhs in
            let a = value(lhs), b = value(rhs)
            switch (a, b) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs["id"].int < rhs["id"].int
            }
        }
    }
}

struct AssetsLoadKey: Equatable {
    let session: AssetsSession?
    let tab: AssetsTab
    let filter: AssetsFilter
    let revision: UUID
}

@MainActor
final class AssetsModel: ObservableObject {
    @Published private(set) var documents: [String: JSONValue] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var saving = false
    @Published private(set) var revision = UUID()
    private(set) var session: AssetsSession?
    private var api: ClipAPI?
    private var generation = UUID()
    private var requests: [String: UUID] = [:]
    private var reads: [String: (id: UUID, task: Task<JSONValue, Error>)] = [:]
    private var loadedAt: [String: Date] = [:]

    var categories: [JSONValue] { document("/api/categories")["items"].array }
    func document(_ path: String) -> JSONValue { documents[path] ?? .null }

    func connect(_ api: ClipAPI?) {
        let next = api.map(AssetsSession.init)
        self.api = api
        guard session != next else { return }
        session = next
        generation = UUID()
        reads.values.forEach { $0.task.cancel() }; reads = [:]
        requests = [:]; loadedAt = [:]
        documents = [:]; failures = [:]; loading = []; saving = false
        revision = UUID()
    }

    func load(_ path: String, force: Bool = false) async {
        guard !Task.isCancelled, let api else { return }
        if !force, let date = loadedAt[path], Date().timeIntervalSince(date) < 30 { return }
        let read: (id: UUID, task: Task<JSONValue, Error>)
        if !force, let active = reads[path] { read = active }
        else {
            reads[path]?.task.cancel()
            read = (UUID(), Task { try await api.document(path) })
            reads[path] = read
        }
        let request = read.id, scope = generation
        requests[path] = request
        loading.insert(path); failures[path] = nil
        defer {
            if generation == scope, requests[path] == request { loading.remove(path); reads[path] = nil }
        }
        do {
            let value = try await read.task.value
            try Task.checkCancellation()
            guard generation == scope, requests[path] == request else { return }
            documents[path] = value
            loadedAt[path] = Date()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard generation == scope, requests[path] == request else { return }
            failures[path] = error.localizedDescription
        }
    }

    @discardableResult
    func write(_ path: String, method: String = "POST", payload: JSONValue? = nil,
               expected: AssetsSession?) async throws -> JSONValue {
        guard let api, let expected, session == expected else { throw ClipError("会话已变化，请重新打开此表单") }
        guard !saving else { throw ClipError("上一笔记录仍在保存，请稍后再试") }
        try Task.checkCancellation()
        let scope = generation
        saving = true
        defer { if generation == scope { saving = false } }
        let value = try await api.document(path, method: method, payload: payload)
        guard generation == scope else { throw CancellationError() }
        // A read started before this write must not repopulate the invalidated cache.
        reads.values.forEach { $0.task.cancel() }; reads = [:]
        requests = [:]; loading = []; loadedAt = [:]
        revision = UUID()
        return value
    }

    func exportData(expected: AssetsSession?) async throws -> Data {
        guard let api, let expected, session == expected else { throw ClipError("会话已变化，请重试") }
        let scope = generation
        let data = try await api.bytes("/api/export")
        guard generation == scope else { throw CancellationError() }
        return data
    }
}

enum AssetsDisplay {
    static func money(_ value: JSONValue, hidden: Bool, unknown: String = "—") -> String {
        if hidden { return "••••" }
        guard value.numeric != nil else { return unknown }
        return "¥" + Display.money(value)
    }

    static func alertTitle(_ alert: JSONValue, hidden: Bool) -> String {
        guard hidden else { return alert["title"].text }
        return ["over_target": "日耗高于目标", "missing_valuation": "待补估值", "retired_not_sold": "退役物品待处理", "subscription": "仍有订阅在续费", "loss": "卖出后产生净亏损"][alert["kind"].text] ?? "成本提醒"
    }

    static func symbol(_ asset: JSONValue) -> String {
        let name = (asset["name"].text + " " + asset["category_name"].text).lowercased()
        if ["mac", "电脑", "笔记本"].contains(where: name.contains) { return "laptopcomputer" }
        if ["iphone", "手机"].contains(where: name.contains) { return "iphone" }
        if ["相机", "sony", "镜头"].contains(where: name.contains) { return "camera" }
        if ["自行车", "brompton", "骑行"].contains(where: name.contains) { return "bicycle" }
        if ["咖啡", "茶"].contains(where: name.contains) { return "cup.and.saucer" }
        if ["耳机", "airpods"].contains(where: name.contains) { return "headphones" }
        if ["出行", "车"].contains(where: name.contains) { return "car" }
        if ["家居", "生活"].contains(where: name.contains) { return "house" }
        return "shippingbox"
    }

    static func category(_ asset: JSONValue) -> String {
        asset["category_name"].text.isEmpty ? "未分类" : asset["category_name"].text
    }
}

struct AssetsJournalEntry: Identifiable {
    let key: String
    let row: JSONValue
    var id: String { key + "-" + row["id"].text }
    var date: String { row[key == "valuations" ? "as_of" : "occurred_on"].text }
    var amount: JSONValue { row[key == "valuations" ? "value" : "amount"] }
    var label: String {
        let labels = key == "valuations" ? ["manual": "人工估价", "market": "市场行情", "depreciation": "折旧推算"] : key == "costs" ? ["repair": "维修", "accessory": "配件", "consumable": "耗材", "subscription": "订阅", "other": "其他成本"] : ["rental": "出租", "order": "接单", "cashback": "返现", "other": "其他收益"]
        let kind = row[key == "valuations" ? "source" : "kind"].text
        return labels[kind] ?? kind
    }
    var typeTitle: String { key == "valuations" ? "估值快照" : key == "costs" ? "成本" : "收益" }

    static func rows(_ asset: JSONValue, scope: String = "all") -> [Self] {
        let keys: [String] = ["costs", "incomes", "valuations"]
        var entries: [AssetsJournalEntry] = []
        for key in keys where scope == "all" || scope == key {
            for row in asset[key].array {
                entries.append(AssetsJournalEntry(key: key, row: row))
            }
        }
        entries.sort { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id < rhs.id }
            return lhs.date > rhs.date
        }
        return entries
    }
}

func assetStatus(_ status: String) -> String {
    switch status {
    case "in_service": return "在用"
    case "retired": return "已退役"
    case "sold": return "已卖出"
    default: return status
    }
}
