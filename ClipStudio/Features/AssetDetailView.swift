import SwiftUI

enum AssetDetailTab: String, CaseIterable, Identifiable, Hashable {
    case overview = "概览", ledger = "台账", reminders = "提醒"
    var id: String { rawValue }
}

@MainActor
struct AssetDetailView: View {
    let id: Int
    @EnvironmentObject private var model: AssetsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.assetsPrivacy) private var privacy
    @State private var tab: AssetDetailTab = .overview
    @State private var ledgerScope = "all"
    @State private var sheet: AssetsSheet?
    @State private var pending: PendingMutation?
    @State private var failure: String?
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 48
    private var path: String { "/api/assets/\(id)" }
    private var remindersPath: String { "/api/assets/\(id)/reminders" }
    private var asset: JSONValue { model.document(path) }
    private var metrics: JSONValue { asset["metrics"] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let failure { NativeFailure(message: failure) }
                AssetsLoadingStatus(path: path)
                if !asset.isNull {
                    cover
                    headline
                    AssetsSurface {
                        if typeSize.isAccessibilitySize {
                            VStack(spacing: 18) { investment; valuation }.padding(18)
                        } else {
                            HStack(alignment: .top, spacing: 16) { investment; valuation }.padding(18)
                        }
                    }
                    Picker("详情内容", selection: $tab) {
                        ForEach(AssetDetailTab.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("assets-detail-tabs")
                    switch tab {
                    case .overview: overview
                    case .ledger: journal
                    case .reminders: reminders
                    }
                }
            }.padding(20)
        }.background(Theme.background).navigationTitle("物品详情").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("assets-detail-scroll")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !asset.isNull { footer }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { moreMenu } }
            .sheet(item: $sheet) { item in
                switch item {
                case .actions:
                    AssetsQuickActions(subtitle: asset["name"].text, actions: [.cost, .income, .reminder]) { action in
                        sheet = .form(action == .reminder ? AssetForms.reminder(id: id, model: model) : AssetForms.ledger(action == .cost ? "costs" : "incomes", id: id, model: model))
                    }
                case .metrics: AssetsMetricsInfo()
                case .form(let request): NativeForm(request).id(request.id)
                default: EmptyView()
                }
            }
            .confirmationDialog(pending?.title ?? "确认操作", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if let action = pending {
                    Button("确认", role: action.method == "DELETE" ? .destructive : nil) {
                        pending = nil
                        Task { await mutate(action) }
                    }
                }
            }
            .task(id: "\(id)-\(model.revision)") { await load() }
            .refreshable { await load(force: true) }
    }

    private var cover: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) { coverText; coverArt }
            } else {
                HStack(spacing: 12) { coverText; coverArt }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 22))
    }
    private var coverText: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AssetsDisplay.category(asset)).font(.caption).foregroundStyle(Theme.text2)
            Text(asset["name"].text).font(.title2.bold()).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Label(assetStatus(asset["status"].text) + " · \(metrics["hold_days"].int) 天", systemImage: asset["status"].text == "in_service" ? "circle" : "checkmark.circle")
                .font(.caption).foregroundStyle(Theme.accent)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var coverArt: some View {
        Image(systemName: AssetsDisplay.symbol(asset)).font(.system(size: 72, weight: .ultraLight))
            .foregroundStyle(Theme.accent).frame(width: 110, height: 108).accessibilityHidden(true)
    }
    private var headline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("扣残值日均成本").font(.subheadline).foregroundStyle(Theme.text2)
                Spacer()
                Button { sheet = .metrics } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("日均成本如何计算")
            }
            if metrics["net_daily_cost"].isNull {
                Text("待补估值").font(.largeTitle.weight(.semibold)).foregroundStyle(Theme.text)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    AssetsAmount(value: metrics["net_daily_cost"]).font(.system(size: heroSize, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.45)
                        .accessibilityIdentifier("assets-detail-net-cost")
                    Text("/天").font(.subheadline).foregroundStyle(Theme.text2)
                }.foregroundStyle(Theme.text)
            }
            Text(metrics["net_daily_cost"].isNull ? "现在大约还能卖多少钱？补上估值，成本更清楚。" : "收益和残值已计入；这不是当天实际支出。")
                .font(.caption).foregroundStyle(Theme.text2)
            ForEach(Array(metrics["warnings"].array.enumerated()), id: \.offset) { _, warning in
                Label(warning.text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.star)
            }
        }
    }
    private var investment: some View { AssetsMetric(title: "账面投入", value: metrics["book_cost"]) }
    private var valuation: some View { AssetsMetric(title: asset["status"].text == "sold" ? "卖出成交价" : "当前估值", value: metrics["residual_value"], unknown: "待估值") }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 26) {
            AssetsTrend(title: "日均成本走势", points: AssetsChartData.points(asset["trend"].array, fields: [("gross", "日均成本")]), series: ["日均成本"], palette: .itemCost)
            Text("这条线未扣除收益与残值，展示服务器返回的持有期间成本。新增持有成本会改变走势。")
                .font(.caption).foregroundStyle(Theme.text2)
            DisclosureGroup("扣残值与目标走势") {
                AssetsTrend(title: "成本对比", points: comparisonPoints, series: comparisonSeries).padding(.top, 16)
            }.font(.subheadline).tint(Theme.accent)
            serviceProgress
            recovery
            if asset["status"].text == "sold" { soldReview }
            DisclosureGroup("购入信息与备注") {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("购入日期", value: asset["purchase_date"].text)
                    LabeledContent("购入单价", value: AssetsDisplay.money(asset["purchase_price"], hidden: privacy.wrappedValue))
                    LabeledContent("数量", value: asset["quantity"].text)
                    LabeledContent("购入总价", value: AssetsDisplay.money(metrics["purchase_total"], hidden: privacy.wrappedValue))
                    if !asset["tags"].array.isEmpty { Text("标签：" + asset["tags"].array.map(\.text).joined(separator: "、")) }
                    if !asset["note"].text.isEmpty { Text(asset["note"].text).textSelection(.enabled) }
                }.font(.subheadline).padding(.top, 14)
            }.tint(Theme.accent)
        }
    }
    private var comparisonSeries: [String] {
        let hasNet = asset["trend"].array.contains { $0["net"].numeric != nil }
        return hasNet ? (asset["target_daily_cost"].isNull ? ["日均成本", "扣残值日均成本"] : ["日均成本", "扣残值日均成本", "目标日耗"]) : (asset["target_daily_cost"].isNull ? ["日均成本"] : ["日均成本", "目标日耗"])
    }
    private var comparisonPoints: [AssetsChartPoint] {
        var fields = [("gross", "日均成本")]
        if comparisonSeries.contains("扣残值日均成本") { fields.append(("net", "扣残值日均成本")) }
        var points = AssetsChartData.points(asset["trend"].array, fields: fields)
        if let target = asset["target_daily_cost"].numeric {
            points += AssetsChartData.points(asset["trend"].array, fields: [("gross", "目标日耗")]).map { AssetsChartPoint(date: $0.date, label: $0.label, value: target, series: $0.series) }
        }
        return points.sorted { $0.date < $1.date }
    }

    private var serviceProgress: some View {
        AssetsSurface {
            VStack(alignment: .leading, spacing: 16) {
                AssetsSectionTitle(title: "使用进度")
                if !metrics["time_progress"].isNull {
                    ProgressView(value: min(1, max(0, metrics["time_progress"].double))).tint(Theme.accent)
                    LabeledContent("已使用", value: Display.percent(metrics["time_progress"]))
                    LabeledContent("预期寿命", value: asset["expected_life_days"].text + " 天")
                } else { Text("还没有设置预期寿命").foregroundStyle(Theme.text2) }
                if !asset["target_daily_cost"].isNull {
                    LabeledContent("目标日均成本", value: AssetsDisplay.money(asset["target_daily_cost"], hidden: privacy.wrappedValue))
                    Text(metrics["is_on_target"].isNull ? "补充估值后可判断是否达标" : metrics["is_on_target"].flag ? "已达目标日耗" : "高于目标日耗").foregroundStyle(Theme.text2)
                }
            }.font(.subheadline).padding(18)
        }
    }
    private var recovery: some View {
        AssetsSurface {
            VStack(alignment: .leading, spacing: 16) {
                AssetsSectionTitle(title: "收益与回本")
                LabeledContent("累计收益", value: AssetsDisplay.money(metrics["income"], hidden: privacy.wrappedValue))
                LabeledContent("持有成本", value: AssetsDisplay.money(metrics["extra_cost"], hidden: privacy.wrappedValue))
                LabeledContent("回本进度", value: Display.percent(metrics["payback_ratio"]))
                LabeledContent("价值回收率", value: Display.percent(metrics["value_recovery_ratio"]))
                Text("价值回收率 =（收益 + 残值）÷ 账面投入").font(.caption).foregroundStyle(Theme.text2)
            }.font(.subheadline).padding(18)
        }
    }
    private var soldReview: some View {
        AssetsSurface {
            VStack(alignment: .leading, spacing: 16) {
                AssetsSectionTitle(title: "卖出复盘")
                LabeledContent("卖出日期", value: asset["sold_date"].text)
                LabeledContent("卖出渠道", value: asset["sold_channel"].text)
                LabeledContent("成交价", value: AssetsDisplay.money(asset["sold_price"], hidden: privacy.wrappedValue))
                LabeledContent("保值率", value: Display.percent(metrics["retention"]))
                LabeledContent("纯价差", value: AssetsDisplay.money(metrics["pnl"], hidden: privacy.wrappedValue))
                LabeledContent("真实盈亏", value: AssetsDisplay.money(metrics["real_pnl"], hidden: privacy.wrappedValue))
            }.font(.subheadline).padding(18)
        }
    }

    private var journal: some View {
        let rows = AssetsJournalEntry.rows(asset, scope: ledgerScope)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                AssetsSectionTitle(title: "每笔都有来处")
                Menu {
                    Button("记一笔成本") { sheet = .form(AssetForms.ledger("costs", id: id, model: model)) }
                    Button("记一笔收益") { sheet = .form(AssetForms.ledger("incomes", id: id, model: model)) }
                    Button("新增估值快照") { sheet = .form(AssetForms.ledger("valuations", id: id, model: model)) }
                } label: { Label("新增", systemImage: "plus").frame(minHeight: 44) }.accessibilityIdentifier("assets-new-ledger")
            }
            Picker("台账类型", selection: $ledgerScope) {
                Text("全部记录").tag("all"); Text("持有成本").tag("costs"); Text("持有收益").tag("incomes"); Text("估值快照").tag("valuations")
            }.pickerStyle(.menu).accessibilityIdentifier("assets-ledger-filter")
            AssetsSurface {
                ForEach(rows) { entry in
                    journalRow(entry)
                    if entry.id != rows.last?.id { Divider().padding(.leading, 16) }
                }
                if ledgerScope == "all" || ledgerScope == "costs" {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("购入物品", value: AssetsDisplay.money(metrics["purchase_total"], hidden: privacy.wrappedValue))
                        Text(asset["purchase_date"].text + " · 购入信息可在编辑物品中修改").font(.caption).foregroundStyle(Theme.text2)
                    }.padding(16).font(.subheadline)
                }
            }
            if rows.isEmpty { Text("暂时没有这类台账，点新增记下第一笔。").font(.callout).foregroundStyle(Theme.text2) }
        }
    }
    private func journalRow(_ entry: AssetsJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.row["note"].text.isEmpty ? entry.label : entry.row["note"].text).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                Text((privacy.wrappedValue || entry.key == "valuations" ? "" : entry.key == "incomes" ? "+" : "−") + AssetsDisplay.money(entry.amount, hidden: privacy.wrappedValue)).font(.subheadline).monospacedDigit()
            }
            HStack {
                Text(entry.date + " · " + entry.typeTitle + " · " + entry.label).font(.caption).foregroundStyle(Theme.text2)
                Spacer()
                Button(role: .destructive) {
                    pending = PendingMutation(title: "删除这条\(entry.typeTitle)？", path: "/api/assets/\(id)/\(entry.key)/\(entry.row["id"].int)")
                } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                    .accessibilityLabel("删除" + entry.typeTitle).accessibilityIdentifier("assets-delete-" + entry.id)
            }
        }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
    }

    private var reminders: some View {
        let rows = model.document(remindersPath)["items"].array
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                AssetsSectionTitle(title: "到期提醒")
                Button("新增", systemImage: "plus") { sheet = .form(AssetForms.reminder(id: id, model: model)) }
                    .frame(minHeight: 44).accessibilityIdentifier("assets-detail-new-reminder")
            }
            AssetsLoadingStatus(path: remindersPath)
            ForEach(rows, id: \.selfKey) { reminder in
                AssetsSurface {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(reminder["name"].text).font(.headline); Spacer(); Text(reminder["active"].flag ? "启用" : "停用").font(.caption).foregroundStyle(Theme.text2) }
                        Text(reminder["due_on"].text).font(.subheadline).foregroundStyle(Theme.text2)
                        if !privacy.wrappedValue { Text(reminder["text"].text).font(.caption).foregroundStyle(Theme.text2) }
                        if reminder["active"].flag {
                            Button("处理本期") { sheet = .form(AssetForms.completeReminder(reminder, model: model)) }.frame(minHeight: 44)
                        }
                        HStack {
                            Button("编辑") { sheet = .form(AssetForms.reminder(id: id, model: model, existing: reminder)) }.frame(minHeight: 44)
                            Spacer()
                            Button("删除", role: .destructive) { pending = PendingMutation(title: "删除此提醒？", path: "/api/reminders/\(reminder["id"].int)") }.frame(minHeight: 44)
                        }
                    }.padding(18)
                }
            }
            if rows.isEmpty, !model.document(remindersPath).isNull {
                ContentUnavailableView("重要的日子，提前记住", systemImage: "bell", description: Text("添加保修到期、订阅续费或耗材更换提醒。"))
            }
        }
    }

    private var footer: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 10) { recordButton; valuationButton }
            } else { HStack(spacing: 10) { recordButton; valuationButton } }
        }.padding(.horizontal, 20).padding(.vertical, 10).background(Theme.surface)
            .overlay(alignment: .top) { Divider() }
    }
    private var recordButton: some View {
        Button { sheet = .actions } label: { Label("记一笔", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent).disabled(model.saving)
            .accessibilityIdentifier("assets-detail-record")
    }
    private var valuationButton: some View {
        Button { sheet = .form(AssetForms.valuation(asset, model: model)) } label: {
            Label(asset["status"].text == "sold" ? "已按成交价计值" : "更新估值", systemImage: "tag").frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered).tint(Theme.accent).disabled(model.saving || asset["status"].text == "sold")
            .accessibilityIdentifier("assets-detail-valuation")
    }
    private var moreMenu: some View {
        Menu {
            Button("编辑物品", systemImage: "pencil") { sheet = .form(AssetForms.editor(model, asset: asset)) }
            Button(privacy.wrappedValue ? "显示金额" : "隐藏金额", systemImage: "eye") { privacy.wrappedValue.toggle() }
            if asset["status"].text != "sold" {
                Button("记录卖出", systemImage: "arrow.up.right") { sheet = .form(AssetForms.sell(asset, model: model)) }
                Button(asset["status"].text == "retired" ? "重新设为在用" : "设为退役", systemImage: "arrow.triangle.2.circlepath") {
                    let retired = asset["status"].text == "retired"
                    pending = PendingMutation(title: retired ? "将物品重新设为在用？" : "将物品退役？退役后不再计入总览的在用日均成本。", path: retired ? path : "/api/assets/\(id)/retire", method: retired ? "PATCH" : "POST", payload: retired ? .object(["status": .string("in_service")]) : nil)
                }
            }
            Button("删除物品", role: .destructive) { pending = PendingMutation(title: "删除物品及其全部台账和提醒？此操作不可撤销。", path: path) }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .disabled(asset.isNull || model.saving).accessibilityLabel("更多物品操作").accessibilityIdentifier("assets-detail-menu")
    }

    private func load(force: Bool = false) async {
        async let detail: Void = model.load(path, force: force)
        async let categories: Void = model.load("/api/categories", force: force)
        async let reminders: Void = model.load(remindersPath, force: force)
        await (detail, categories, reminders)
    }
    private func mutate(_ action: PendingMutation) async {
        do {
            try await model.write(action.path, method: action.method, payload: action.payload, expected: model.session)
            failure = nil
            if action.path == path, action.method == "DELETE" { dismiss() }
        } catch { failure = error.localizedDescription }
    }
}
