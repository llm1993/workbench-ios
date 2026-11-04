import SwiftUI

private struct AssetsPrivacyKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var assetsPrivacy: Binding<Bool> {
        get { self[AssetsPrivacyKey.self] }
        set { self[AssetsPrivacyKey.self] = newValue }
    }
}

struct AssetsSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Theme.line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct AssetsListSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Theme.line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct AssetsSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline).foregroundStyle(Theme.text)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.text2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AssetsAmount: View {
    let value: JSONValue
    var unknown = "—"
    @Environment(\.assetsPrivacy) private var privacy
    var body: some View { Text(AssetsDisplay.money(value, hidden: privacy.wrappedValue, unknown: unknown)) }
}

struct AssetsMetric: View {
    let title: String
    let value: JSONValue
    var unit: String? = nil
    var unknown = "—"
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                AssetsAmount(value: value, unknown: unknown).font(.title2.weight(.semibold)).minimumScaleFactor(0.65).lineLimit(1)
                if let unit { Text(unit).font(.caption).foregroundStyle(Theme.text2) }
            }.foregroundStyle(Theme.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AssetsRow: View {
    let asset: JSONValue
    var compact = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.assetsPrivacy) private var privacy

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(asset["name"].text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Text(AssetsDisplay.category(asset) + " · " + assetStatus(asset["status"].text)).font(.caption).foregroundStyle(Theme.text2)
            if !compact, !asset["metrics"]["hold_days"].isNull {
                Text("已持有 \(asset["metrics"]["hold_days"].int) 天").font(.caption2).foregroundStyle(Theme.text2)
            }
            if !asset["tags"].array.isEmpty {
                Text(asset["tags"].array.map(\.text).joined(separator: "、")).font(.caption2).foregroundStyle(Theme.text2).lineLimit(2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var amounts: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 5) {
            Text(AssetsDisplay.money(asset["metrics"]["gross_daily_cost"], hidden: privacy.wrappedValue) + " /天")
                .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(Theme.text)
            Text(asset["metrics"]["residual_value"].isNull ? "估值待补" : "估值 " + AssetsDisplay.money(asset["metrics"]["residual_value"], hidden: privacy.wrappedValue))
                .font(.caption2).foregroundStyle(Theme.text2)
        }.fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: AssetsDisplay.symbol(asset)).font(.system(size: 27, weight: .light))
                .foregroundStyle(Theme.accent).frame(width: 48, height: 52)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { metadata; amounts }
            } else {
                metadata; amounts
            }
        }.padding(.vertical, 16).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

struct AssetsTaskRow: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body).foregroundStyle(Theme.star)
                .frame(width: 36, height: 40).background(Theme.star.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                Text(detail).font(.caption).foregroundStyle(Theme.text2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.text2)
        }.padding(14).frame(minHeight: 70).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

enum AssetsAction: String, CaseIterable, Identifiable {
    case newAsset, cost, income, valuation, wish, reminder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newAsset: return "新增一件物品"
        case .cost: return "记一笔成本"
        case .income: return "记一笔收益"
        case .valuation: return "更新估值"
        case .wish: return "记下一个心愿"
        case .reminder: return "添加提醒"
        }
    }
    var subtitle: String {
        switch self {
        case .newAsset: return "先记名称、价格和购入日期"
        case .cost: return "维修、配件、耗材和订阅"
        case .income: return "出租、接单或返现"
        case .valuation: return "现在大约还能卖多少钱"
        case .wish: return "慢慢攒，不用马上买"
        case .reminder: return "保修、续费或耗材更换"
        }
    }
    var symbol: String {
        switch self {
        case .newAsset: return "shippingbox"
        case .cost: return "wrench.and.screwdriver"
        case .income: return "arrow.down.left"
        case .valuation: return "tag"
        case .wish: return "heart"
        case .reminder: return "bell"
        }
    }
}

enum AssetsSheet: Identifiable {
    case actions, picker(AssetsAction), filters, sort, reminders, metrics, form(FormRequest)
    var id: String {
        switch self {
        case .actions: return "actions"
        case .picker(let action): return "pick-" + action.rawValue
        case .filters: return "filters"
        case .sort: return "sort"
        case .reminders: return "reminders"
        case .metrics: return "metrics"
        case .form(let form): return form.id.uuidString
        }
    }
}

struct AssetsSheetFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.presentationDragIndicator(.visible)
    }
}

@MainActor
struct AssetsQuickActions: View {
    @EnvironmentObject private var model: AssetsModel
    var subtitle: String? = nil
    var actions: [AssetsAction] = [.newAsset, .cost, .income, .valuation, .wish]
    let select: (AssetsAction) -> Void
    var body: some View {
        AssetsSheetFrame(title: "记一笔") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Theme.text2) }
                    if actions.contains(.newAsset) { AssetsLoadingStatus(path: "/api/categories") }
                    AssetsSurface {
                        ForEach(actions) { action in
                            Button { select(action) } label: {
                                AssetsTaskRow(title: action.title, detail: action.subtitle, symbol: action.symbol)
                            }.buttonStyle(.plain).disabled(action == .newAsset && model.document("/api/categories").isNull)
                                .accessibilityIdentifier("assets-action-" + action.rawValue)
                            if action != actions.last { Divider().padding(.leading, 62) }
                        }
                    }
                }.padding(20)
            }.background(Theme.background)
        }
    }
}

@MainActor
struct AssetsPicker: View {
    let action: AssetsAction
    let select: (JSONValue) -> Void
    @EnvironmentObject private var model: AssetsModel
    @State private var query = ""
    private let path = "/api/assets"
    private var rows: [JSONValue] {
        model.document(path)["items"].array.filter {
            (action != .valuation || $0["status"].text != "sold") && (query.isEmpty || $0["name"].text.localizedStandardContains(query))
        }
    }
    var body: some View {
        let matching = rows
        AssetsSheetFrame(title: "先选一件物品") {
            ScrollView {
                VStack(spacing: 16) {
                    Text(action.title + "，要记到哪件物品？").font(.subheadline).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading)
                    AssetsLoadingStatus(path: path)
                    AssetsListSurface {
                        ForEach(matching, id: \.selfKey) { asset in
                            Button { select(asset) } label: { AssetsRow(asset: asset, compact: true) }
                                .buttonStyle(.plain).accessibilityIdentifier("assets-pick-\(asset["id"].int)")
                            if asset.selfKey != matching.last?.selfKey { Divider().padding(.leading, 74) }
                        }
                    }
                    if matching.isEmpty, !model.document(path).isNull {
                        ContentUnavailableView("没有匹配的物品", systemImage: "shippingbox", description: Text("可以换个关键词，或先新增一件物品。"))
                    }
                }.padding(20)
            }.background(Theme.background).searchable(text: $query, prompt: "搜索物品")
        }.task(id: model.revision) { await model.load(path) }
    }
}

struct AssetsFilters: View {
    let categories: [JSONValue]
    let apply: (AssetsFilter) -> Void
    @State private var draft: AssetsFilter
    @Environment(\.dismiss) private var dismiss
    init(filter: AssetsFilter, categories: [JSONValue], apply: @escaping (AssetsFilter) -> Void) {
        _draft = State(initialValue: filter); self.categories = categories; self.apply = apply
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("物品状态") {
                    Picker("状态", selection: $draft.status) {
                        Text("全部状态").tag("")
                        ForEach(["in_service", "retired", "sold"], id: \.self) { Text(assetStatus($0)).tag($0) }
                    }.pickerStyle(.inline).accessibilityIdentifier("assets-status-filter")
                }
                Section("品类与标签") {
                    Picker("品类", selection: $draft.category) {
                        Text("全部品类").tag("")
                        ForEach(categories, id: \.selfKey) { Text($0["name"].text).tag($0["id"].text) }
                    }
                    TextField("按标签筛选", text: $draft.tag).accessibilityIdentifier("assets-tag-filter")
                }
                Button("清除全部筛选") { draft = AssetsFilter(sort: draft.sort) }
            }.navigationTitle("筛选家底").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("应用") { apply(draft) }.accessibilityIdentifier("assets-apply-filter") }
                }
        }
    }
}

@MainActor
struct AssetsLoadingStatus: View {
    let path: String
    @EnvironmentObject private var model: AssetsModel
    var body: some View {
        if let failure = model.failures[path] {
            VStack(alignment: .leading, spacing: 8) {
                NativeFailure(message: failure)
                Button("重新加载") { Task { await model.load(path, force: true) } }.frame(minHeight: 44)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if model.loading.contains(path), model.document(path).isNull {
            ProgressView("正在加载…").frame(maxWidth: .infinity, minHeight: 80)
        }
    }
}

struct AssetsMetricsInfo: View {
    var body: some View {
        AssetsSheetFrame(title: "这些数字怎么算") {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AssetsSectionTitle(title: "账面投入", subtitle: "购入单价 × 数量 + 持有成本。")
                    AssetsSectionTitle(title: "日均成本", subtitle: "账面投入 ÷ 持有天数。总览只合计在用物品；列表展示每件物品的这一指标。")
                    AssetsSectionTitle(title: "扣残值日均成本", subtitle: "（账面投入 − 收益 − 残值）÷ 持有天数。估值未知时不当作零元；净成本可以为负数。")
                    AssetsSectionTitle(title: "物品净值", subtitle: "使用当前残值；未知估值暂按账面投入计入，并标明待估值数量。已卖出物品使用成交价。")
                    Text("购入当天和截至当天都计入持有天数。所有指标由服务器统一计算，日均成本不是当天实际支出。")
                        .font(.callout).foregroundStyle(Theme.text2)
                }.padding(20)
            }.background(Theme.background)
        }
    }
}
