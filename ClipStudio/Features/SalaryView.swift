import SwiftUI
import CryptoKit

private struct SalaryScrollOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SalaryInputs: Equatable {
    let draft: JSONValue
    let offerA: JSONValue
    let offerB: JSONValue
    let raise: Double
}

struct SalaryView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric private var heroSize: CGFloat = 40
    @State private var scene = SalaryScene.calc
    @State private var month = 1
    @State private var withBonus = false
    @State private var showEmployer = false
    @State private var raiseDelta = 1000.0
    @State private var defaults: JSONValue = .null
    @State private var draft: JSONValue = .null
    @State private var result: JSONValue = .null
    @State private var tables: JSONValue = .null
    @State private var cities: [JSONValue] = []
    @State private var engine: SalaryEngine?
    @State private var failure: String?
    @State private var sheet: SalarySheet?
    @State private var presets: [SalaryPreset] = []
    @State private var activePreset: Int?
    @State private var offerA: JSONValue = .null
    @State private var offerB: JSONValue = .null
    @State private var offerAResult: JSONValue = .null
    @State private var offerBResult: JSONValue = .null
    @State private var marginal: JSONValue = .null
    @State private var trap: JSONValue = .null
    @State private var ownerScope: String?
    @State private var toast: String?
    @State private var share: RelayShare?
    @State private var scrolled = false

    private var accountScope: String { (store.account?.base.absoluteString ?? "") + "|" + (store.account?.username ?? "") }
    private var presentation: SalaryPresentation {
        SalaryPresentation(result: result, tables: tables, month: month, withBonus: withBonus)
    }
    private var inputs: SalaryInputs { SalaryInputs(draft: draft, offerA: offerA, offerB: offerB, raise: raiseDelta) }
    private var ready: Bool { !result.isNull }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pageHeader.id("salary-top")
                        if let failure { NativeFailure(message: failure).accessibilityIdentifier("salary-failure") }
                        if ready {
                            switch scene {
                            case .calc: calcScene
                            case .slip: SalarySlipScene(presentation: presentation, showEmployer: $showEmployer,
                                                        selectMonth: selectMonth, copy: copySlip, export: exportSlip)
                            case .compare: SalaryCompareScene(presentation: presentation, offerA: $offerA, offerB: $offerB,
                                                              offerAResult: offerAResult, offerBResult: offerBResult,
                                                              marginal: marginal, trap: trap, raiseDelta: $raiseDelta,
                                                              cities: cities, syncOffer: syncOffer)
                            }
                        } else {
                            SalaryPanel {
                                Label("先把测算参数填完整", systemImage: "slider.horizontal.3").font(.headline)
                                Text("计算全部在本机完成，不读取账户数据，也不上传工资。")
                                    .font(.subheadline).foregroundStyle(SalaryStyle.secondary)
                            }
                        }
                        footer
                    }.frame(maxWidth: 700).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 26)
                        .frame(maxWidth: .infinity)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: SalaryScrollOffset.self,
                                                       value: geometry.frame(in: .named("salary-scroll")).minY)
                            }
                        }
                }.id(scene).accessibilityIdentifier("salary-scroll")
                    .scrollDismissesKeyboard(.interactively)
                    .coordinateSpace(name: "salary-scroll")
                    .onPreferenceChange(SalaryScrollOffset.self) { scrolled = $0 < -300 }
                if let toast { toastView(toast) }
            }.safeAreaInset(edge: .top, spacing: 0) {
                if scene == .calc && scrolled && ready { stickyNet(proxy) }
            }.safeAreaInset(edge: .bottom, spacing: 0) { sceneTabs }
        }.background(SalaryStyle.background.ignoresSafeArea()).foregroundStyle(SalaryStyle.text).tint(SalaryStyle.accent)
            .navigationTitle("到手工资").toolbarBackground(SalaryStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { planMenu }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { dismissKeyboard() }
                }
            }
            .sheet(item: $sheet) { item in
                SalarySheetView(sheet: item, presentation: presentation, presets: presets, activePreset: activePreset,
                                cities: cities, tables: tables, trap: trap, monthlyNet: presetNet,
                                apply: applyPreset, savePreset: savePreset, selectMonth: { selectMonth($0); sheet = nil },
                                copy: copySlip, export: exportSlip)
            }
            .sheet(item: $share) { item in NativeShareSheet(item: item) { _ in share = nil } }
            .task { await initialize() }
            .task(id: inputs) {
                do { try await Task.sleep(for: .milliseconds(220)); try Task.checkCancellation(); recalculate(); saveLocal() }
                catch { }
            }
            .task(id: toast) {
                guard toast != nil else { return }
                try? await Task.sleep(for: .milliseconds(1900))
                toast = nil
            }
            .onDisappear { saveLocal() }
            .onChange(of: phase) { _, value in if value != .active { saveLocal() } }
    }

    // MARK: - 外壳

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { sceneTitle.fixedSize(); Spacer(minLength: 0); draftStatus.fixedSize() }
                VStack(alignment: .leading, spacing: 10) { sceneTitle; draftStatus }
            }
            Text(scene.subtitle).font(.subheadline).foregroundStyle(SalaryStyle.secondary)
        }.padding(.vertical, 8)
    }
    private var sceneTitle: some View {
        Text(scene.heading).font(.largeTitle.weight(.semibold)).tracking(-0.8)
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
    private var draftTitle: String {
        if let index = activePreset, presets.indices.contains(index) { return presets[index].name }
        return "本机草稿"
    }
    private var draftStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").accessibilityHidden(true)
            Text(draftTitle)
                .lineLimit(1).truncationMode(.middle)
        }.font(.caption).foregroundStyle(SalaryStyle.accent).padding(.horizontal, 10).padding(.vertical, 6)
            .background(SalaryStyle.tint, in: Capsule()).accessibilityElement(children: .combine)
            .accessibilityIdentifier("salary-draft-status")
    }
    private var sceneTabs: some View {
        Group {
            if typeSize.isAccessibilitySize { VStack(spacing: 4) { sceneButtons } }
            else { HStack(spacing: 6) { sceneButtons } }
        }.frame(maxWidth: 700).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8).frame(maxWidth: .infinity)
            .background {
                SalaryStyle.surface.ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) { Rectangle().fill(SalaryStyle.line).frame(height: 0.7) }
            }.accessibilityElement(children: .contain).accessibilityLabel("到手工资功能导航")
            .accessibilityIdentifier("salary-navigation")
    }
    private var sceneButtons: some View {
        ForEach(SalaryScene.allCases) { item in
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
                    .foregroundStyle(scene == item ? SalaryStyle.accent : SalaryStyle.secondary)
                    .background(scene == item ? SalaryStyle.tint : .clear, in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityAddTraits(scene == item ? .isSelected : [])
                .accessibilityIdentifier("salary-scene-" + item.rawValue)
        }
    }
    private var planMenu: some View {
        Menu {
            Button("示例方案与本机方案", systemImage: "folder") { sheet = .plans }
            Button("把当前参数存为方案", systemImage: "doc.badge.plus") { savePreset() }
            Button("恢复默认示例", systemImage: "arrow.counterclockwise") { reset() }
            Button("导出工资条", systemImage: "square.and.arrow.up") { exportSlip() }
        } label: { Label("方案", systemImage: "folder") }.accessibilityIdentifier("salary-plans")
    }
    private func stickyNet(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Text(presentation.monthTitle).font(.caption).foregroundStyle(SalaryStyle.secondary)
            Text("¥" + SalaryDisplay.money(presentation.net)).font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(SalaryStyle.net).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Button("回到顶部") { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("salary-top", anchor: .top) } }
                .font(.caption.weight(.medium)).frame(minHeight: 36).accessibilityIdentifier("salary-back-top")
        }.padding(.horizontal, 20).padding(.vertical, 6).frame(maxWidth: .infinity)
            .background {
                SalaryStyle.surface.ignoresSafeArea(edges: .top)
                    .overlay(alignment: .bottom) { Rectangle().fill(SalaryStyle.line).frame(height: 0.7) }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("salary-sticky")
    }
    private func toastView(_ message: String) -> some View {
        Text(message).font(.subheadline).foregroundStyle(SalaryStyle.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 11).background(SalaryStyle.accent, in: Capsule())
            .padding(.bottom, 96).transition(.opacity).accessibilityIdentifier("salary-toast")
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scene == .slip ? "工资条按当前测算参数生成，不代表任何真实单位的发放结果。"
                 : "按居民个人工资薪金累计预扣预缴法测算，未含全年一次性奖金以外的其他所得、公益捐赠与汇算清缴补退。")
            Text("城市社保与公积金预设是示例值，实际以当地社保年度公布口径和工资条为准。")
            Text("年终奖单独计税政策执行至 2027-12-31（财政部 税务总局公告 2023 年第 30 号）。")
            Button("计算口径与说明") { sheet = .explain }.frame(minHeight: 44).accessibilityIdentifier("salary-about")
        }.font(.caption).foregroundStyle(SalaryStyle.secondary).padding(.horizontal, 3)
    }

    // MARK: - 到手试算

    private var calcScene: some View {
        VStack(alignment: .leading, spacing: 18) {
            SalaryNotice(messages: presentation.notices)
            hero
            SalaryControls(draft: draft, cities: cities, insurance: presentation.insurance, special: presentation.special,
                           bonusModeTitle: presentation.bonusModeTitle, edit: edit, random: randomize, reset: reset,
                           export: exportSlip, standards: { sheet = .standards }, cityInfo: { sheet = .cities })
            SalaryChartPanel(presentation: presentation, withBonus: $withBonus, select: selectMonth,
                             detail: { sheet = .year }, explain: { sheet = .explain })
            invite
        }
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack { monthButton; Spacer(minLength: 8); heroBadge }
                    VStack(alignment: .leading, spacing: 8) { monthButton; heroBadge }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("¥").font(.title3.weight(.medium)).foregroundStyle(SalaryStyle.net)
                    Text(SalaryDisplay.money(presentation.net))
                        .font(.system(size: heroSize, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(SalaryStyle.net).lineLimit(1).minimumScaleFactor(0.45)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("salary-net")
                Text(presentation.summary).font(.caption).foregroundStyle(SalaryStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(20)
            SalaryTearLine()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(presentation.flow) { SalaryReceiptLine(line: $0) }
                }
                SalaryFlowBar(shares: presentation.shares, summary: presentation.shareSummary)
                Divider().overlay(SalaryStyle.line)
                SalaryMetricRow(metrics: presentation.metrics)
                insightButton
            }.padding(20)
        }.background(SalaryStyle.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(SalaryStyle.line, lineWidth: 0.7) }
            // Without .contain a container's identifier overwrites every descendant's, hiding salary-net & friends.
            .accessibilityElement(children: .contain).accessibilityIdentifier("salary-hero")
    }
    private var monthButton: some View {
        Button { sheet = .month } label: {
            Label(presentation.monthTitle, systemImage: "calendar").font(.subheadline.weight(.medium))
                .foregroundStyle(SalaryStyle.accent)
        }.buttonStyle(.plain).frame(minHeight: 36).accessibilityIdentifier("salary-month-button")
    }
    private var heroBadge: some View {
        Text(presentation.badge).font(.caption.weight(.medium)).monospacedDigit()
            .foregroundStyle(presentation.badgeIsJump ? SalaryStyle.tax : SalaryStyle.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(presentation.badgeIsJump ? SalaryStyle.soft(.tax) : SalaryStyle.tint, in: Capsule())
            .fixedSize().accessibilityIdentifier("salary-hero-badge")
    }
    private var insightButton: some View {
        Button { changeScene(.compare) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb").font(.subheadline).foregroundStyle(SalaryStyle.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.insight).font(.caption).foregroundStyle(SalaryStyle.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(presentation.insightAction).font(.caption.weight(.semibold)).foregroundStyle(SalaryStyle.accent)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(SalaryStyle.secondary).accessibilityHidden(true)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(SalaryStyle.tint, in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("salary-insight")
    }
    private var invite: some View {
        Button { changeScene(.compare) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.up.right").font(.headline).foregroundStyle(SalaryStyle.accent)
                    .frame(width: 42, height: 42).background(SalaryStyle.tint, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("换个 offer，到手差多少？").font(.subheadline.weight(.semibold))
                    Text(presentation.invite).font(.caption).foregroundStyle(SalaryStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("去对比 →").font(.caption.weight(.semibold)).foregroundStyle(SalaryStyle.accent)
                }
                Spacer(minLength: 0)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(SalaryStyle.tint, in: RoundedRectangle(cornerRadius: 22)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("salary-invite")
    }

    // MARK: - 状态与动作

    private func edit(_ key: String, _ value: JSONValue) {
        draft[key] = value
        activePreset = nil
        if key == "city", let city = cities.first(where: { $0["key"].text == value.text }) {
            draft["fundRate"] = .number(city["fund"].double)
            if !offerA.isNull { offerA["city"] = value }
        }
        if key == "startMonth" { month = max(month, value.int) }
    }
    private func selectMonth(_ value: Int) { month = min(12, max(1, value)) }
    private func changeScene(_ next: SalaryScene) {
        dismissKeyboard()
        scene = next
        if next == .compare { offerA = draft; recalculate() }
    }
    private func syncOffer() { offerA = draft; recalculate(); toast = "A 已同步当前参数" }
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private func applyPreset(_ index: Int) {
        guard presets.indices.contains(index) else { return }
        draft = presets[index].data
        activePreset = index
        month = max(1, draft["startMonth"].int)
        offerA = draft
        sheet = nil
        recalculate(); saveLocal()
        toast = "已套用：" + presets[index].name
    }
    private func savePreset() {
        guard !draft.isNull else { return }
        let custom = presets.count - SalaryPresets.builtIn(defaults).count + 1
        let city = cities.first { $0["key"].text == draft["city"].text }?["name"].text ?? ""
        presets.append(SalaryPreset(name: "我的方案 \(custom)",
                                    desc: "\(city) · 月薪 \(SalaryDisplay.whole(draft["gross"].double)) · 年终奖 \(SalaryDisplay.whole(draft["bonus"].double))",
                                    data: draft))
        activePreset = presets.count - 1
        saveLocal()
        toast = "已存为本机方案"
    }
    private func reset() {
        draft = defaults
        activePreset = 0
        month = 1
        withBonus = false
        offerA = draft
        offerB = alternativeOffer(draft)
        recalculate(); saveLocal()
        toast = "已恢复默认示例"
    }
    private func randomize() {
        guard let city = cities.filter({ $0["key"].text != "custom" }).randomElement() else { return }
        var next = defaults
        next["city"] = .string(city["key"].text)
        next["gross"] = .number(Double([12000, 18000, 25000, 32000, 45000, 60000, 80000].randomElement() ?? 32000))
        next["fundRate"] = .number(city["fund"].double)
        next["bonus"] = .number(Double([0, 20000, 36000, 60000, 120000, 200000].randomElement() ?? 60000))
        next["children"] = .integer([0, 1, 2].randomElement() ?? 1)
        next["infants"] = .integer([0, 0, 1].randomElement() ?? 0)
        next["elder"] = .string(["only", "share", "none"].randomElement() ?? "only")
        next["housing"] = .string(["loan", "rent", "none"].randomElement() ?? "rent")
        next["rentTier"] = .integer([0, 1, 2].randomElement() ?? 0)
        next["study"] = .bool(Double.random(in: 0..<1) < 0.3)
        next["pension"] = .number(Double([0, 0, 1000].randomElement() ?? 0))
        draft = next
        activePreset = nil
        offerA = draft
        recalculate(); saveLocal()
        toast = "换了一组示例参数"
    }
    private func alternativeOffer(_ base: JSONValue) -> JSONValue {
        var value = base
        value["gross"] = .number(38000)
        value["bonus"] = .number(90000)
        value["fundRate"] = .number(12)
        value["city"] = .string("beijing")
        return value
    }
    private func copySlip() {
        UIPasteboard.general.string = presentation.slipText(trap: trap)
        toast = "工资条已复制"
    }
    private func exportSlip() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("工资条-\(month)月.txt")
            try Data(presentation.slipText(trap: trap).utf8).write(to: url, options: [.atomic, .completeFileProtection])
            share = RelayShare(url: url, remoteID: 0, accountScope: "", keyID: "")
        } catch { failure = "导出失败：\(error.localizedDescription)" }
    }

    // MARK: - 计算与本机草稿

    private var localURL: URL? {
        guard ownerScope == accountScope, let account = store.account else { return nil }
        let key = SHA256.hash(data: Data((account.base.absoluteString + "|" + account.username).utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("salary-\(key).json")
    }
    private func initialize() async {
        ownerScope = accountScope
        do {
            let e = try SalaryEngine(); engine = e
            defaults = try e.call("defaults")
            tables = try e.call("tables")
            cities = try e.call("cities").array
            presets = SalaryPresets.builtIn(defaults)
            draft = defaults
            activePreset = 0
            if let url = localURL, let data = try? Data(contentsOf: url),
               let saved = try? JSONDecoder().decode(JSONValue.self, from: data), !saved["draft"].isNull {
                draft = saved["draft"]
                month = min(12, max(1, saved["month"].int == 0 ? 1 : saved["month"].int))
                activePreset = saved["active"].isNull ? nil : saved["active"].int
                if let list = try? JSONDecoder().decode([SalaryPreset].self, from: JSONEncoder().encode(saved["presets"])), !list.isEmpty {
                    presets = list
                }
                if !saved["offerB"].isNull { offerB = saved["offerB"] }
                if saved["raise"].double > 0 { raiseDelta = saved["raise"].double }
            }
            offerA = draft
            if offerB.isNull { offerB = alternativeOffer(draft) }
            recalculate()
        } catch { failure = error.localizedDescription }
    }
    private func recalculate() {
        guard let engine, !draft.isNull else { return }
        do {
            result = try engine.compute(draft)
            marginal = try engine.marginal(draft, delta: raiseDelta)
            trap = try engine.bonusTrap(draft["bonus"].double)
            offerAResult = try engine.compute(offerA.isNull ? draft : offerA)
            offerBResult = try engine.compute(offerB.isNull ? draft : offerB)
            failure = nil
        } catch {
            result = .null
            failure = error.localizedDescription
        }
    }
    private func presetNet(_ data: JSONValue) -> Double {
        guard let engine, let value = try? engine.compute(data) else { return 0 }
        return value["main"]["avgNet"].double
    }
    private func saveLocal() {
        guard let url = localURL, !draft.isNull else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let list = (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(presets))) ?? .array([])
            let value: JSONValue = .object(["draft": draft, "presets": list, "month": .integer(month),
                                            "active": activePreset.map { JSONValue.integer($0) } ?? .null,
                                            "offerB": offerB, "raise": .number(raiseDelta)])
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        } catch { failure = "本机草稿保存失败，请先导出工资条再离开。" }
    }
}