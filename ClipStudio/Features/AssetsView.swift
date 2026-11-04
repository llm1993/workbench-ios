import SwiftUI
import UniformTypeIdentifiers

private enum AssetsDestination: Hashable {
    case detail(Int)
    case statistics
}

@MainActor
struct AssetsView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var model = AssetsModel()
    @State private var tab: AssetsTab = .overview
    @State private var filter = AssetsFilter()
    @State private var hideAmounts = false
    @State private var sheet: AssetsSheet?
    @State private var destination: AssetsDestination?
    @State private var pendingCreatedAsset: Int?
    @State private var pendingTab: AssetsTab?
    @State private var pending: PendingMutation?
    @State private var actionFailure: String?
    @State private var export: TextExport?
    @State private var exporting = false
    @State private var exportingData = false
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 52

    private let dashboardPath = "/api/stats/dashboard"
    private let remindersPath = "/api/reminders"
    private let currentAssetsPath = ClipAPI.path("/api/assets", query: ["status": "in_service", "sort": "purchase_date", "order": "desc"])
    private var overview: JSONValue { model.document(dashboardPath)["overview"] }
    private var due: [JSONValue] { model.document(remindersPath)["items"].array }
    private var pendingValues: [JSONValue] { overview["pending_valuation"].array }
    private var loadKey: AssetsLoadKey {
        AssetsLoadKey(session: store.api.map(AssetsSession.init), tab: tab, filter: filter, revision: model.revision)
    }
    private var paths: [String] {
        let common = ["/api/categories", remindersPath]
        switch tab {
        case .overview: return common + [dashboardPath, currentAssetsPath]
        case .inventory: return common + [dashboardPath, filter.path]
        case .wishes: return common + ["/api/wishes"]
        case .review: return common + ["/api/stats/review", "/api/stats/waste"]
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let actionFailure { NativeFailure(message: actionFailure) }
                switch tab {
                case .overview: dashboard
                case .inventory: inventory
                case .wishes:
                    AssetsWishesContent(create: { sheet = .form(newWishForm()) }, deposit: { sheet = .form(AssetForms.deposit($0, model: model)) }, remove: {
                        pending = PendingMutation(title: "删除此心愿及攒钱记录？", path: "/api/wishes/\($0["id"].int)")
                    })
                case .review: AssetsReviewContent(openAsset: { destination = .detail($0) }, showStatistics: { destination = .statistics })
                }
            }.padding(20)
        }.id(tab).background(Theme.background).scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("assets-scroll")
            .navigationTitle("有数").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .toolbar { toolbar }
            .sheet(item: $sheet, onDismiss: {
                if let next = pendingTab { pendingTab = nil; tab = next }
                if let id = pendingCreatedAsset { pendingCreatedAsset = nil; destination = .detail(id) }
            }) { item in modal(item) }
            .navigationDestination(item: $destination) { target in
                Group {
                    switch target {
                    case .detail(let id): AssetDetailView(id: id)
                    case .statistics: AssetsStatisticsView()
                    }
                }.environmentObject(model).environment(\.assetsPrivacy, $hideAmounts)
            }
            .confirmationDialog(pending?.title ?? "确认操作", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if let action = pending {
                    Button("确认删除", role: .destructive) {
                        pending = nil
                        let expected = model.session
                        Task {
                            do { try await model.write(action.path, method: action.method, payload: action.payload, expected: expected); actionFailure = nil }
                            catch { actionFailure = error.localizedDescription }
                        }
                    }
                }
            }
            .fileExporter(isPresented: $exporting, document: export, contentType: .plainText, defaultFilename: "有数-\(Display.today).jsonl") { result in
                if case .failure(let error) = result { actionFailure = error.localizedDescription }
                export = nil
            }
            .task(id: loadKey) {
                model.connect(store.api)
                do {
                    if tab == .inventory, !filter.query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
                    try Task.checkCancellation()
                    await load()
                } catch { }
            }
            .refreshable { await load(force: true) }
            .environmentObject(model).environment(\.assetsPrivacy, $hideAmounts)
    }

    private var dashboard: some View {
        Group {
            AssetsLoadingStatus(path: dashboardPath)
            if !overview.isNull {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("物品净值").font(.subheadline).foregroundStyle(Theme.text2)
                        Spacer()
                        Button { hideAmounts.toggle() } label: { Image(systemName: hideAmounts ? "eye.slash" : "eye") }
                            .frame(width: 44, height: 44).foregroundStyle(Theme.text2)
                            .accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额").accessibilityIdentifier("assets-privacy")
                    }
                    AssetsAmount(value: overview["net_value"]).font(.system(size: heroSize, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.45).foregroundStyle(Theme.text).accessibilityIdentifier("assets-net-value")
                    Button { sheet = .metrics } label: {
                        Label("\(overview["asset_count"].int) 件物品" + (pendingValues.isEmpty ? "" : "，含 \(pendingValues.count) 件待估值"), systemImage: "info.circle")
                            .font(.caption).frame(minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                summary
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        AssetsSectionTitle(title: "待处理", subtitle: pendingValues.isEmpty && due.isEmpty ? "暂时没有待办" : "\(pendingValues.count + due.count) 件待办")
                        Button("查看提醒", systemImage: "chevron.right") { sheet = .reminders }.font(.caption).frame(minHeight: 44)
                    }
                    AssetsLoadingStatus(path: remindersPath)
                    if !pendingValues.isEmpty || !due.isEmpty {
                        AssetsSurface {
                            ForEach(Array(pendingValues.prefix(3)), id: \.selfKey) { asset in
                                Button { sheet = .form(AssetForms.valuation(asset, model: model)) } label: {
                                    AssetsTaskRow(title: asset["name"].text + " · 待补估值", detail: "补上二手价，真实日耗更准确", symbol: "tag")
                                }.buttonStyle(.plain).accessibilityIdentifier("assets-pending-\(asset["id"].int)")
                                Divider().padding(.leading, 62)
                            }
                            ForEach(Array(due.prefix(3)), id: \.selfKey) { reminder in
                                Button { sheet = .form(AssetForms.completeReminder(reminder, model: model)) } label: {
                                    AssetsTaskRow(title: reminder["name"].text, detail: reminder["due_on"].text + (reminder["overdue"].flag ? " · 已到期" : " · 即将到期"), symbol: "calendar")
                                }.buttonStyle(.plain).accessibilityIdentifier("assets-reminder-\(reminder["id"].int)")
                                if reminder.selfKey != due.prefix(3).last?.selfKey { Divider().padding(.leading, 62) }
                            }
                        }
                    } else if !model.document(remindersPath).isNull {
                        Label("好好使用喜欢的东西，其他事情都记下了。", systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(Theme.text2).padding(.vertical, 6)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        AssetsSectionTitle(title: "在用物品")
                        Button("查看家底", systemImage: "chevron.right") { tab = .inventory }.font(.caption).frame(minHeight: 44)
                    }
                    AssetsLoadingStatus(path: currentAssetsPath)
                    assetRows(Array(model.document(currentAssetsPath)["items"].array.prefix(3)), compact: true)
                    if model.document(currentAssetsPath)["items"].array.isEmpty, !model.document(currentAssetsPath).isNull {
                        Button("新增第一件在用物品", systemImage: "plus") { sheet = .form(newAssetForm()) }.frame(minHeight: 44)
                    }
                }
                Button { destination = .statistics } label: {
                    AssetsTaskRow(title: "完整统计", detail: "净值走势、月度投入和资产状态", symbol: "chart.xyaxis.line")
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 18) { summaryInvestment; summaryDaily }.padding(.top, 18).overlay(alignment: .top) { Divider() }
        } else {
            HStack(alignment: .top, spacing: 16) {
                summaryInvestment
                Rectangle().fill(Theme.line).frame(width: 1, height: 52)
                summaryDaily
            }.padding(.top, 18).overlay(alignment: .top) { Divider() }
        }
    }
    private var summaryInvestment: some View { AssetsMetric(title: "累计投入", value: overview["book_cost"]) }
    private var summaryDaily: some View { AssetsMetric(title: "在用日均成本", value: overview["daily_burn"], unit: "/天") }

    private var inventory: some View {
        let document = model.document(filter.path), rows = filter.rows(document)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("我的家底").font(.largeTitle.bold()).foregroundStyle(Theme.text)
                    if !overview.isNull {
                        Text("\(overview["by_status"]["in_service"]["count"].int) 件在用，\(overview["by_status"]["retired"]["count"].int) 件已退役")
                            .font(.caption).foregroundStyle(Theme.text2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { sheet = .filters } label: {
                    Label("筛选", systemImage: filter.hasRestrictions ? "line.3.horizontal.decrease.circle.fill" : "slider.horizontal.3")
                        .font(.subheadline).padding(.horizontal, 12).frame(minHeight: 44)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                }.accessibilityIdentifier("assets-filters")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text2)
                TextField("搜索一件物品", text: $filter.query).submitLabel(.search).accessibilityIdentifier("assets-search")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清除搜索").frame(minWidth: 44, minHeight: 44)
                }
            }.padding(.horizontal, 14).frame(minHeight: 48).background(Theme.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryChip("全部", id: "")
                    ForEach(model.categories, id: \.selfKey) { categoryChip($0["name"].text, id: $0["id"].text) }
                }
            }.accessibilityIdentifier("assets-categories")
            HStack(alignment: .firstTextBaseline) {
                Text("\(rows.count) 件物品 · " + (filter.status.isEmpty ? "全部状态" : assetStatus(filter.status)))
                    .font(.caption).foregroundStyle(Theme.text2)
                Spacer()
                Button("按" + filter.sort.title, systemImage: "arrow.up.arrow.down") { sheet = .sort }
                    .font(.caption).frame(minHeight: 44).accessibilityIdentifier("assets-sort")
            }
            if !filter.tag.isEmpty { Text("标签：" + filter.tag).font(.caption).foregroundStyle(Theme.accent) }
            AssetsLoadingStatus(path: filter.path)
            AssetsLoadingStatus(path: "/api/categories")
            assetRows(rows)
            if rows.isEmpty, !document.isNull, model.failures[filter.path] == nil {
                ContentUnavailableView(filter.hasRestrictions ? "没有匹配的物品" : "家底从一件物品开始", systemImage: "shippingbox", description: Text(filter.hasRestrictions ? "试试其他关键词，或清除筛选。" : "记录价格与购入日期，看看每天的拥有成本。"))
                Button(filter.hasRestrictions ? "清除筛选" : "新增一件物品") {
                    if filter.hasRestrictions { filter = AssetsFilter(sort: filter.sort) }
                    else { sheet = .form(newAssetForm()) }
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            Text("日均成本未扣除收益与残值。点开物品，可以查看扣残值后的成本。")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }

    private func categoryChip(_ title: String, id: String) -> some View {
        Button { filter.category = id } label: {
            Text(title).font(.subheadline.weight(filter.category == id ? .semibold : .regular))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .foregroundStyle(filter.category == id ? Theme.onAccent : Theme.text2)
                .background(filter.category == id ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(filter.category == id ? .isSelected : [])
            .accessibilityIdentifier("assets-category-" + (id.isEmpty ? "all" : id))
    }

    @ViewBuilder private func assetRows(_ rows: [JSONValue], compact: Bool = false) -> some View {
        if !rows.isEmpty {
            AssetsListSurface {
                ForEach(rows, id: \.selfKey) { asset in
                    Button { destination = .detail(asset["id"].int) } label: { AssetsRow(asset: asset, compact: compact) }
                        .buttonStyle(.plain).accessibilityIdentifier("assets-row-\(asset["id"].int)")
                    if asset.selfKey != rows.last?.selfKey { Divider().padding(.leading, 74) }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton(.overview); tabButton(.inventory)
            Button { sheet = .actions } label: {
                Image(systemName: "plus").font(.title2.weight(.regular)).foregroundStyle(Theme.onAccent)
                    .frame(width: 52, height: 52).background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 58)
                .accessibilityLabel("新增或记一笔").accessibilityIdentifier("assets-quick-add")
            tabButton(.wishes); tabButton(.review)
        }.padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 5)
            .background(Theme.surface).overlay(alignment: .top) { Divider() }
    }
    private func tabButton(_ item: AssetsTab) -> some View {
        Button { tab = item } label: {
            VStack(spacing: 5) {
                Image(systemName: item.symbol).font(.system(size: 21, weight: item == tab ? .semibold : .regular))
                if !typeSize.isAccessibilitySize { Text(item.title).font(.caption2) }
            }.foregroundStyle(item == tab ? Theme.accent : Theme.text2).frame(maxWidth: .infinity, minHeight: 58)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityAddTraits(item == tab ? .isSelected : [])
            .accessibilityIdentifier("assets-tab-" + item.rawValue)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { sheet = .reminders } label: {
                Image(systemName: "bell").overlay(alignment: .topTrailing) {
                    if !due.isEmpty { Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 5, y: -3) }
                }.frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("提醒与待办，\(pendingValues.count + due.count) 件待办").accessibilityIdentifier("assets-reminders")
            Menu {
                Button("完整统计") { destination = .statistics }
                Button(hideAmounts ? "显示金额" : "隐藏金额", systemImage: hideAmounts ? "eye" : "eye.slash") { hideAmounts.toggle() }
                Button("指标口径", systemImage: "info.circle") { sheet = .metrics }
                Button(exportingData ? "正在导出…" : "导出全部数据", systemImage: "square.and.arrow.up") { Task { await exportData() } }.disabled(exportingData)
            } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("更多有数操作").accessibilityIdentifier("assets-menu")
        }
    }

    @ViewBuilder private func modal(_ item: AssetsSheet) -> some View {
        switch item {
        case .actions: AssetsQuickActions { action in
            switch action {
            case .newAsset: sheet = .form(newAssetForm())
            case .wish: sheet = .form(newWishForm())
            default: sheet = .picker(action)
            }
        }
        case .picker(let action): AssetsPicker(action: action) { asset in
            if action == .valuation { sheet = .form(AssetForms.valuation(asset, model: model)) }
            else { sheet = .form(AssetForms.ledger(action == .cost ? "costs" : "incomes", id: asset["id"].int, model: model)) }
        }
        case .filters: AssetsFilters(filter: filter, categories: model.categories) { filter = $0; sheet = nil }
        case .sort:
            AssetsSheetFrame(title: "物品排序") {
                List(AssetsSort.allCases) { option in
                    Button { filter.sort = option; sheet = nil } label: {
                        HStack { Text(option.title); Spacer(); if filter.sort == option { Image(systemName: "checkmark") } }.frame(minHeight: 44)
                    }.accessibilityIdentifier("assets-sort-" + option.rawValue)
                }
            }.presentationDetents([.medium, .large])
        case .reminders: AssetsRemindersView()
        case .metrics: AssetsMetricsInfo()
        case .form(let request): NativeForm(request).id(request.id)
        }
    }

    private func newAssetForm() -> FormRequest {
        AssetForms.editor(model) { pendingCreatedAsset = $0 }
    }

    private func newWishForm() -> FormRequest {
        AssetForms.wish(model) { pendingTab = .wishes }
    }

    private func load(force: Bool = false) async {
        let source = model
        await withTaskGroup(of: Void.self) { group in
            for path in paths { group.addTask { await source.load(path, force: force) } }
        }
    }
    private func exportData() async {
        guard !exportingData else { return }; exportingData = true
        defer { exportingData = false }
        do { export = TextExport(data: try await model.exportData(expected: model.session)); exporting = true }
        catch { actionFailure = error.localizedDescription }
    }
}
