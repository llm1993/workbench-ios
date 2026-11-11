import SwiftUI
import JavaScriptCore
import CryptoKit

@MainActor
final class MortgageEngine {
    private let context: JSContext
    private var exception: String?
    init() throws {
        guard let c = JSContext() else { throw ClipError("无法初始化计算器") }; context = c
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() }
        for name in ["calc", "rates", "native-bridge"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { throw ClipError("缺少房贷计算资源") }
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            if exception != nil { throw ClipError("房贷计算资源初始化失败") }
        }
    }
    func call(_ function: String, args: [Any] = []) throws -> JSONValue {
        exception = nil
        guard let string = context.objectForKeyedSubscript("NativeMortgage")?.objectForKeyedSubscript(function)?.call(withArguments: args)?.toString(), exception == nil else {
            throw ClipError(exception?.replacingOccurrences(of: "Error: ", with: "") ?? "房贷计算失败")
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }
    func calculate(kind: String, data: JSONValue) throws -> JSONValue {
        let json = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
        return try call("calculate", args: [kind, json, Display.today])
    }
}

struct MortgageView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var scene = MortgageScene.trial
    @State private var kind = "new"
    @State private var strategy = "term"
    @State private var inputsExpanded = false
    @State private var drafts: JSONValue = .object([:])
    @State private var plans: [JSONValue] = []
    @State private var selected: JSONValue = .null
    @State private var calculation: JSONValue = .null
    @State private var engine: MortgageEngine?
    @State private var failure: String?
    @State private var busy = false
    @State private var naming = false
    @State private var name = ""
    @State private var saveAs = false
    @State private var conflict: JSONValue = .null
    @State private var deleting = false
    @State private var form: FormRequest?
    @State private var detailSheet: MortgageSheet?
    @State private var historyPart = 0
    @State private var switching: JSONValue?
    @State private var savedDraft: JSONValue = .null
    @State private var selections: JSONValue = .object([:])
    @State private var snapshots: JSONValue = .object([:])
    @State private var ownerScope: String?
    private var accountScope: String { (store.account?.base.absoluteString ?? "") + "|" + (store.account?.username ?? "") }
    private var draft: JSONValue { drafts[kind] }
    private var dirty: Bool { selected.isNull || draft != savedDraft }
    private var isPrepayment: Bool { scene == .prepayment }
    private var presentation: MortgagePresentation { MortgagePresentation(kind: kind, draft: draft, calculation: calculation, prepayment: isPrepayment, strategy: strategy) }
    private var needsInputs: Bool { inputsExpanded || calculation.isNull || (isPrepayment && !presentation.hasPrepayment) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader.id("mortgage-top")
                    if let failure { NativeFailure(message: failure).accessibilityIdentifier("mortgage-failure") }
                    if !calculation.isNull && (!isPrepayment || presentation.hasPrepayment) {
                        MortgageSummaryCard(presentation: presentation, actionTitle: isPrepayment ? "比较两种还法" : kind == "new" ? "对比还款方式" : "查看还款计划") {
                            detailSheet = isPrepayment ? .strategies : kind == "new" ? .methods : .schedule
                        }
                    } else {
                        MortgagePanel {
                            Label(isPrepayment ? "先设置这笔提前还款" : "先把贷款参数填完整", systemImage: isPrepayment ? "wallet.bifold" : "slider.horizontal.3").font(.headline)
                            Text(isPrepayment ? "选择时间、金额和还款方式，再看月供与利息会怎样变化。" : "计算在本机完成。正在还的房贷，请照着合同和银行 App 填写。")
                                .font(.subheadline).foregroundStyle(MortgageStyle.secondary)
                        }
                    }
                    inputsCard
                    if !calculation.isNull && (!isPrepayment || presentation.hasPrepayment) {
                        if scene == .current { currentOverview }
                        MortgageBalanceChart(series: presentation.chartSeries, months: presentation.chartMonths,
                                             title: isPrepayment ? "提前还款前后" : "本金还款走势",
                                             subtitle: isPrepayment ? "原计划与提前还款后的剩余本金" : kind == "new" ? "两种还款方式的剩余本金变化" : "未来利率按现有利率表推算",
                                             schedule: { detailSheet = .schedule }, showData: { detailSheet = .chartData })
                        if !isPrepayment { prepaymentInvitation }
                    }
                    footer
                }.frame(maxWidth: 700).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 26).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("mortgage-scroll")
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scene) { _, _ in proxy.scrollTo("mortgage-top", anchor: .top) }
        }.safeAreaInset(edge: .bottom, spacing: 0) { sceneTabs }
            .disabled(busy)
            .background(MortgageStyle.background.ignoresSafeArea()).foregroundStyle(MortgageStyle.text).tint(MortgageStyle.accent)
            .navigationTitle("房贷计算器").toolbarBackground(MortgageStyle.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { planMenu.disabled(busy) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .refreshable { do { try await reloadPlans() } catch is CancellationError { } catch { failure = error.localizedDescription } }
            .sheet(item: $form) { NativeForm($0).tint(MortgageStyle.accent) }
            .sheet(item: $detailSheet) { sheet in
                MortgageDetailSheet(sheet: sheet, presentation: presentation, initialContract: historyPart,
                                    selectMethod: { drafts["new"]["method"] = .string($0); recalculate(); saveLocal() },
                                    selectStrategy: { strategy = $0 })
            }
            .alert("方案名称", isPresented: $naming) {
                TextField("名称（最多 40 字）", text: $name)
                Button("取消", role: .cancel) { }
                Button("保存") { Task { await save() } }
            }
            .confirmationDialog("删除云端方案？本机草稿会保留。", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除方案", role: .destructive) { Task { await remove() } }
            }
            .confirmationDialog("此方案已在其他设备修改。", isPresented: Binding(get: { !conflict.isNull }, set: { if !$0 { conflict = .null } }), titleVisibility: .visible) {
                Button("载入云端最新方案") { choose(conflict); conflict = .null }
                Button("用本机修改覆盖最新版本", role: .destructive) {
                    let stamp = conflict["updated_at"].text; conflict = .null
                    Task { await save(base: stamp) }
                }
                Button("保留本机草稿", role: .cancel) { conflict = .null }
            }
            .confirmationDialog("切换方案会替换当前未保存修改。", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }), titleVisibility: .visible) {
                Button(dirty ? "舍弃修改并切换" : "打开方案", role: dirty ? .destructive : nil) {
                    if let next = switching { choose(next) }; switching = nil
                }
                Button("取消", role: .cancel) { switching = nil }
            }
            .task { await initialize() }
            .task(id: draft) {
                do { try await Task.sleep(for: .milliseconds(220)); try Task.checkCancellation(); recalculate(); saveLocal() }
                catch { }
            }
            .onDisappear { saveLocal() }
            .onChange(of: phase) { _, value in if value != .active { saveLocal() } }
    }
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { sceneTitle.fixedSize(); Spacer(minLength: 0); draftStatus.fixedSize() }
                VStack(alignment: .leading, spacing: 10) { sceneTitle; draftStatus }
            }
            Text(scene.subtitle).font(.subheadline).foregroundStyle(MortgageStyle.secondary)
            if !selected.isNull { cloudStatus }
        }.padding(.vertical, 8)
    }
    private var sceneTitle: some View {
        Text(scene.title).font(.largeTitle.weight(.semibold)).tracking(-0.8).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
    private var draftStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: selected.isNull ? "doc.text" : "icloud").accessibilityHidden(true)
            Text(selected.isNull ? "本机草稿" : selected["name"].text).lineLimit(1).truncationMode(.middle)
            if busy { ProgressView().controlSize(.small) }
        }.font(.caption).foregroundStyle(MortgageStyle.accent).padding(.horizontal, 10).padding(.vertical, 6)
            .background(MortgageStyle.tint, in: Capsule()).accessibilityElement(children: .combine)
    }
    private var cloudStatus: some View {
        Text(dirty ? "有修改未存云端" : "已存云端").font(.caption).foregroundStyle(MortgageStyle.secondary)
    }
    private var sceneTabs: some View {
        Group {
            if typeSize.isAccessibilitySize { VStack(spacing: 4) { sceneButtons } }
            else { HStack(spacing: 6) { sceneButtons } }
        }.frame(maxWidth: 700).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8).frame(maxWidth: .infinity)
            .background {
                MortgageStyle.surface.ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) { Rectangle().fill(MortgageStyle.line).frame(height: 0.7) }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("房贷功能导航")
            .accessibilityIdentifier("mortgage-navigation")
    }
    private var sceneButtons: some View {
        ForEach(MortgageScene.allCases) { item in
            Button { changeScene(item) } label: {
                Group {
                    if typeSize.isAccessibilitySize {
                        Label(item.title, systemImage: scene == item ? item.selectedSymbol : item.symbol)
                            .font(.subheadline.weight(scene == item ? .semibold : .regular))
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: scene == item ? item.selectedSymbol : item.symbol).font(.system(size: 20, weight: .medium))
                            Text(item.title).font(.caption.weight(scene == item ? .semibold : .regular))
                        }
                    }
                }.frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 50 : 56).padding(.vertical, 4)
                    .foregroundStyle(scene == item ? MortgageStyle.accent : MortgageStyle.secondary)
                    .background(scene == item ? MortgageStyle.tint : .clear, in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityAddTraits(scene == item ? .isSelected : [])
                .accessibilityIdentifier("mortgage-scene-" + item.rawValue)
        }
    }
    private var planMenu: some View {
        Menu {
            Section(selected.isNull ? "本机草稿" : selected["name"].text) {
                Button("保存到云端", systemImage: "icloud.and.arrow.up") { beginSave(asNew: false) }
                Button("另存为新方案", systemImage: "doc.badge.plus") { beginSave(asNew: true) }
            }
            Section("\(kind == "new" ? "试算" : "我的房贷")方案") {
                Button("新建草稿", systemImage: "plus") { switching = .null }
                ForEach(plans.filter { $0["kind"].text == kind }, id: \.selfKey) { plan in
                    Button(plan["name"].text) { switching = plan }
                }
            }
            if !selected.isNull { Button("删除云端方案", role: .destructive) { deleting = true } }
        } label: { Label("方案", systemImage: "folder") }
            .accessibilityIdentifier("mortgage-plans")
    }
    private var inputsCard: some View {
        MortgagePanel {
            Button { inputsExpanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Label(isPrepayment ? "提前还款设置" : kind == "current" ? "贷款合同" : "贷款参数", systemImage: "slider.horizontal.3").font(.headline)
                        Spacer(minLength: 0)
                        Label(needsInputs ? "收起" : "修改", systemImage: needsInputs ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.medium)).foregroundStyle(MortgageStyle.accent)
                            .padding(.horizontal, 10).padding(.vertical, 7).background(MortgageStyle.tint, in: Capsule())
                    }
                    if !needsInputs {
                        if kind == "new" && !isPrepayment {
                            if typeSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 12) { parameterFacts } }
                            else { HStack(spacing: 12) { parameterFacts } }
                        } else {
                            Text(kind == "current" ? "\(draft["parts"].array.count) 笔合同 · 历史调整与还款记录" : "沿用当前贷款，调整提前还款金额和时间")
                                .font(.caption).foregroundStyle(MortgageStyle.secondary)
                        }
                    }
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("mortgage-input-toggle").accessibilityValue(needsInputs ? "已展开" : "已收起")
            if needsInputs {
                Divider().overlay(MortgageStyle.line)
                if isPrepayment { prepaymentInputs }
                else if kind == "new" { MortgageTrialInputs(draft: binding(kind), compare: { detailSheet = .methods }) }
                else { currentInputs }
                Button { beginSave(asNew: false) } label: {
                    Label("保存到云端", systemImage: "icloud.and.arrow.up").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 48)
                        .background(MortgageStyle.hero, in: RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(.plain).accessibilityIdentifier("mortgage-save")
                Text("修改即计算，本机草稿与云端方案分开保存。")
                    .font(.caption).foregroundStyle(MortgageStyle.secondary)
            }
        }
    }
    private var parameterFacts: some View {
        Group {
            MortgageQuickFact(title: "贷款金额", value: MortgageDisplay.wan(calculation["total"]) + " 万")
            MortgageQuickFact(title: "贷款年限", value: draft["years"].text + " 年")
            MortgageQuickFact(title: draft["type"].text == "combo" ? "贷款类型" : "年利率", value: trialRateSummary)
        }
    }
    private var trialRateSummary: String {
        if draft["type"].text == "combo" { return "组合贷款" }
        let rate = draft["type"].text == "fund" ? draft["fundRate"].double : draft["lpr"].double + draft["bp"].double / 100
        return MortgageDisplay.number(rate) + "%"
    }
    private var prepaymentInputs: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("基于哪份贷款计算").font(.subheadline)
            MortgageSegment(title: "提前还款来源", options: [MortgageOption(id: "new", title: "买房试算"), MortgageOption(id: "current", title: "我的房贷")], selection: Binding(get: { kind }, set: { changeKind($0) }))
            Text(kind == "new" ? "沿用买房试算里的金额、利率和还款方式。" : "沿用我的房贷合同、历史调整和银行本金校准。")
                .font(.caption).foregroundStyle(MortgageStyle.secondary)
            MortgageFields(fields: prepaymentFields, value: binding(kind))
            Text(kind == "new" ? "在所选期次的常规还款之后，提前还这笔钱。" : "0 期表示现在还；否则在指定期次正常还款之后提前还。")
                .font(.caption).foregroundStyle(MortgageStyle.secondary)
            Divider().overlay(MortgageStyle.line)
            Text("提前还款后").font(.subheadline)
            MortgageStrategyOption(title: "缩短年限", detail: "月供或每期本金基本不变，更早还清", selected: strategy == "term") { strategy = "term" }
                .accessibilityIdentifier("mortgage-strategy-term")
            MortgageStrategyOption(title: "减少月供", detail: "保留剩余期数，每月压力更小", selected: strategy == "payment") { strategy = "payment" }
                .accessibilityIdentifier("mortgage-strategy-payment")
        }
    }
    private var prepaymentFields: [FormField] {
        if kind == "current" {
            return [FormField(id: "extraAmount", title: "计划提前还（万元）", kind: .number),
                    FormField(id: "extraWhen", title: "现在之后第几期（0 = 马上）", kind: .integer),
                    FormField(id: "extraPart", title: "提前还哪一笔", kind: .choice(draft["parts"].array.indices.map { FormChoice(id: String($0), title: "合同 \($0 + 1)") })),
                    FormField(id: "scenarioLpr", title: "下次 LPR（%，留空沿用）", kind: .number)]
        }
        var fields = [FormField(id: "preAmount", title: "计划提前还（万元）", kind: .number), FormField(id: "preMonth", title: "还满多少期后", kind: .integer)]
        if draft["type"].text == "combo" { fields.append(FormField(id: "prePart", title: "提前还哪一笔", kind: .choice(choices([("commercial", "商业贷款"), ("fund", "公积金贷款")])))) }
        return fields
    }
    private var methodField: FormField { FormField(id: "method", title: "还款方式", kind: .choice(choices([("equal", "等额本息"), ("principal", "等额本金")]))) }
    private var currentInputs: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(draft["parts"].array.enumerated()), id: \.offset) { i, part in
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("合同 \(i + 1)").font(.headline)
                        Spacer()
                        if draft["parts"].array.count > 1 {
                            Button("移除", role: .destructive) { var parts = draft["parts"].array; parts.remove(at: i); drafts[kind]["parts"] = .array(parts); drafts[kind]["extraPart"] = .number(0) }.font(.caption)
                        }
                    }
                    MortgageFields(fields: partFields(part), value: partBinding(i))
                    adjustments(i, part: part, key: "changes", title: "利率 / 加点调整")
                    adjustments(i, part: part, key: "prepays", title: "已发生的提前还款")
                }
                Divider().overlay(MortgageStyle.line)
            }
            if draft["parts"].array.count < 2 {
                Button("再加一笔（组合贷另一半）", systemImage: "plus") {
                    do { if let engine { drafts[kind]["parts"] = .array(draft["parts"].array + [try engine.call("part")]) } }
                    catch { failure = error.localizedDescription }
                }.font(.subheadline)
            }
            DisclosureGroup("未来利率情景") {
                MortgageFields(fields: [FormField(id: "scenarioLpr", title: "下次 LPR（%，留空沿用）", kind: .number)], value: binding(kind)).padding(.top, 12)
            }.font(.subheadline)
        }
    }
    private func partFields(_ part: JSONValue) -> [FormField] {
        var fields = [FormField(id: "kind", title: "类型", kind: .choice(choices([("commercial", "商业贷款"), ("fund", "公积金贷款")]))),
                      FormField(id: "amount", title: "原始金额（万元）", kind: .number), FormField(id: "years", title: "合同年限", kind: .number),
                      FormField(id: "start", title: "放款日 YYYY-MM-DD", kind: .text), FormField(id: "firstDue", title: "首次还款日（可空）", kind: .text), methodField]
        if part["kind"].text == "commercial" {
            fields.append(FormField(id: "rateMode", title: "利率方式", kind: .choice(choices([("lpr", "LPR + 加点"), ("fixed", "固定利率")]))))
            if part["rateMode"].text == "lpr" {
                fields += [FormField(id: "bp", title: "初始加点（基点）", kind: .text), FormField(id: "reprice", title: "重定价", kind: .choice(choices([("jan1", "每年 1 月 1 日"), ("anniv", "放款周年日")])))]
            }
        }
        fields += [FormField(id: "rate", title: "起始 / 固定利率（%）", kind: .number), FormField(id: "bank", title: "银行剩余本金（元，可空）", kind: .number)]
        return fields
    }
    private func adjustments(_ i: Int, part: JSONValue, key: String, title: String) -> some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(part[key].array.enumerated()), id: \.offset) { j, row in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row["date"].text)
                            Text(key == "changes" ? row["value"].text : row["amount"].text + " 万元 / " + (row["mode"].text == "payment" ? "减少月供" : "缩短年限"))
                        }.font(.caption)
                        Spacer()
                        Button("删除", role: .destructive) { var rows = drafts[kind]["parts"][i][key].array; rows.remove(at: j); drafts[kind]["parts"][i][key] = .array(rows) }.font(.caption)
                    }
                }
                Button("记一条", systemImage: "plus") {
                    var fields = [FormField(id: "date", title: "发生日期", kind: .date, required: true)]
                    if key == "changes" { fields += [FormField(id: "value", title: part["rateMode"].text == "lpr" && part["kind"].text == "commercial" ? "新加点（基点）" : "新利率（%）", required: true)] }
                    else { fields += [FormField(id: "amount", title: "提前还款（万元）", kind: .number, required: true, min: 0), FormField(id: "mode", title: "方式", kind: .choice(choices([("term", "缩短年限"), ("payment", "减少月供")])))] }
                    form = FormRequest(title: title, fields: fields, initial: .object(["date": .string(Display.today), "mode": .string("term")])) { value in
                        if key == "changes", value["value"].numeric == nil { throw ClipError("利率或加点必须是有效数字") }
                        drafts[kind]["parts"][i][key] = .array(drafts[kind]["parts"][i][key].array + [value])
                    }
                }.font(.subheadline)
            }.padding(.top, 12)
        }.font(.subheadline)
    }
    private var currentOverview: some View {
        ForEach(Array(calculation["parts"].array.enumerated()), id: \.offset) { i, part in
            MortgagePanel {
                HStack { Text("合同 \(i + 1) 的还款进度").font(.headline); Spacer(); Text("\(part["paidCount"].int) / \(part["total"].int) 期").font(.caption).foregroundStyle(MortgageStyle.secondary) }
                ProgressView(value: Double(part["paidCount"].int), total: Double(max(1, part["total"].int)))
                    .accessibilityLabel("合同 \(i + 1) 还款进度").accessibilityValue("已还 \(part["paidCount"].int) 期，共 \(part["total"].int) 期")
                LabeledContent("已还本金", value: Display.money(part["paidPrincipal"]) + " 元")
                LabeledContent("当前利率", value: part["rateNow"].text + "%")
                DisclosureGroup("合同详情") {
                    VStack(spacing: 12) {
                        LabeledContent("已付利息", value: Display.money(part["paidInterest"]))
                        LabeledContent("剩余本金", value: Display.money(part["balance"]))
                        LabeledContent("还剩期数", value: part["remainingMonths"].text)
                        LabeledContent("下次重定价", value: part["nextReprice"].isNull ? "—" : part["nextReprice"].text)
                        LabeledContent("重定价后利率", value: part["rateAfterReprice"].isNull ? "—" : part["rateAfterReprice"].text + "%")
                        LabeledContent("预计结清", value: part["endDate"].text)
                    }.font(.caption).padding(.top, 12)
                }
                Button("查看已还明细", systemImage: "list.bullet.rectangle") { historyPart = i; detailSheet = .history }.font(.subheadline)
            }.font(.subheadline)
        }
    }
    private var prepaymentInvitation: some View {
        Button { changeScene(.prepayment) } label: {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "arrow.up.forward.circle.fill").font(.system(size: 30, weight: .regular)).foregroundStyle(MortgageStyle.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text("提前还一笔，能省多少？").font(.subheadline.weight(.semibold))
                    Text(presentation.hasPrepayment ? "按当前提前还款设置，缩短年限可少付 \(MortgageDisplay.wan(presentation.savedInterest(for: "term"))) 万元利息。" : "选个时间和金额，看看利息能少多少。")
                        .font(.caption).foregroundStyle(MortgageStyle.secondary)
                    Label("算算能省多少", systemImage: "arrow.right").font(.caption.weight(.semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20).background(MortgageStyle.tint, in: RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityIdentifier("mortgage-prepay-invitation")
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("按月计息，结果仅供参考。实际还款以银行合同、计息规则及审批为准。", systemImage: "info.circle")
            if !calculation["asOf"].text.isEmpty { Text("默认利率表截至 \(calculation["asOf"].text)，非实时报价，可手动修改。") }
            Button("计算口径与说明") { detailSheet = .about }.frame(minHeight: 44)
        }.font(.caption).foregroundStyle(MortgageStyle.secondary).padding(.horizontal, 3)
    }
    private func changeScene(_ next: MortgageScene) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        scene = next
        if next == .trial { changeKind("new") }
        else if next == .current { changeKind("current") }
        inputsExpanded = next == .prepayment || calculation.isNull
    }
    private func changeKind(_ next: String) {
        guard next != kind else { return }
        selections[kind] = selected; snapshots[kind] = savedDraft
        kind = next; selected = selections[next]; savedDraft = snapshots[next]
        recalculate(); saveLocal()
    }
    private func beginSave(asNew: Bool) {
        saveAs = asNew
        name = asNew || selected.isNull ? (kind == "new" ? "买房试算" : "我的房贷") : selected["name"].text
        naming = true
    }
    private func binding(_ key: String) -> Binding<JSONValue> { Binding(get: { drafts[key] }, set: { drafts[key] = $0 }) }
    private func partBinding(_ i: Int) -> Binding<JSONValue> { Binding(get: { drafts[kind]["parts"][i] }, set: { drafts[kind]["parts"][i] = $0 }) }
    private var localURL: URL? {
        guard ownerScope == accountScope, let account = store.account else { return nil }
        let key = SHA256.hash(data: Data((account.base.absoluteString + "|" + account.username).utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("mortgage-\(key).json")
    }
    private func initialize() async {
        ownerScope = accountScope
        do {
            let e = try MortgageEngine(); engine = e; drafts = try e.call("defaults")
            if let url = localURL, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(JSONValue.self, from: data) {
                if saved["drafts"].isNull { drafts = saved }
                else { drafts = saved["drafts"]; selections = saved["selected"]; snapshots = saved["saved"]; selected = selections[kind]; savedDraft = snapshots[kind] }
            }
            recalculate(); try await reloadPlans()
        } catch { failure = error.localizedDescription }
    }
    private func recalculate() {
        guard let engine else { return }
        do {
            calculation = try engine.calculate(kind: kind, data: draft); failure = nil
            if isPrepayment && !presentation.hasPrepayment { inputsExpanded = true }
        } catch {
            calculation = .null; failure = error.localizedDescription; inputsExpanded = true
        }
    }
    private func saveLocal() {
        guard let url = localURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            selections[kind] = selected; snapshots[kind] = savedDraft
            let value: JSONValue = .object(["drafts": drafts, "selected": selections, "saved": snapshots])
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        } catch { failure = "本机草稿保存失败，请先保存到云端再离开。" }
    }
    private func choose(_ plan: JSONValue) {
        selected = plan; savedDraft = plan["data"]
        if !plan.isNull { drafts[kind] = plan["data"]; name = plan["name"].text }
        else if let engine, let defaults = try? engine.call("defaults") { drafts[kind] = defaults[kind] }
        recalculate(); saveLocal()
    }
    private func reloadPlans() async throws {
        guard let api = store.api else { return }
        let scope = accountScope
        let result = try await api.document("/api/mortgage/plans")
        guard scope == accountScope, ownerScope == scope else { throw CancellationError() }
        plans = result["items"].array
    }
    private func save(base: String? = nil) async {
        guard !busy, let api = store.api else { return }; busy = true; defer { busy = false }
        let scope = accountScope, submitted = draft
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.unicodeScalars.count <= 40 else { throw ClipError("方案名称应为 1–40 字") }
            if let engine { _ = try engine.calculate(kind: kind, data: draft) }
            var payload: JSONValue = .object(["name": .string(title), "data": submitted])
            let next: JSONValue
            if !selected.isNull && !saveAs {
                payload["base"] = .string(base ?? selected["updated_at"].text)
                next = try await api.document("/api/mortgage/plans/\(selected["id"].int)", method: "PUT", payload: payload)
            } else { payload["kind"] = .string(kind); next = try await api.document("/api/mortgage/plans", method: "POST", payload: payload) }
            guard scope == accountScope, ownerScope == scope else { throw CancellationError() }
            selected = next; savedDraft = submitted; saveLocal(); try await reloadPlans(); failure = nil
        } catch let e as HTTPFailure where e.status == 409 {
            if let data = e.payload, let value = try? JSONDecoder().decode(JSONValue.self, from: data), !value["current"].isNull { conflict = value["current"] }
            else { failure = e.localizedDescription }
        } catch { failure = error.localizedDescription }
    }
    private func remove() async {
        guard !busy, let api = store.api, !selected.isNull else { return }; busy = true; defer { busy = false }
        let scope = accountScope
        do {
            _ = try await api.document("/api/mortgage/plans/\(selected["id"].int)", method: "DELETE")
            guard scope == accountScope, ownerScope == scope else { throw CancellationError() }
            selected = .null; savedDraft = .null; saveLocal(); try await reloadPlans()
        } catch { failure = error.localizedDescription }
    }
}
