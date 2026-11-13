import SwiftUI

struct MortgageDetailSheet: View {
    let sheet: MortgageSheet
    let presentation: MortgagePresentation
    let selectMethod: (String) -> Void
    let selectStrategy: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var scheduleKey: String
    @State private var contract: Int
    @State private var monthly = false

    init(sheet: MortgageSheet, presentation: MortgagePresentation, initialContract: Int = 0,
         selectMethod: @escaping (String) -> Void, selectStrategy: @escaping (String) -> Void) {
        self.sheet = sheet; self.presentation = presentation
        self.selectMethod = selectMethod; self.selectStrategy = selectStrategy
        _scheduleKey = State(initialValue: presentation.resultKey)
        _contract = State(initialValue: initialContract)
    }
    private var title: String {
        switch sheet {
        case .methods: return "两种还法，放在一起看"
        case .strategies: return "提前还款，怎么选？"
        case .schedule: return "还款计划明细"
        case .chartData: return "剩余本金数据"
        case .history: return "已还款明细"
        case .about: return "计算口径与说明"
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch sheet {
                    case .methods, .strategies: comparison
                    case .schedule, .history: schedule
                    case .chartData: chartData
                    case .about: about
                    }
                }.frame(maxWidth: 700).padding(20).frame(maxWidth: .infinity)
            }.background(MortgageStyle.background).foregroundStyle(MortgageStyle.text)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("mortgage-sheet-close") } }
        }.tint(MortgageStyle.accent).presentationDragIndicator(.visible)
    }
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(sheet == .strategies ? "相同提前还款金额，不同的月供与结清时间。" : "贷款金额、利率与年限相同，比较的是还款方式。")
                .font(.subheadline).foregroundStyle(MortgageStyle.secondary)
            if typeSize.isAccessibilitySize {
                VStack(spacing: 14) { comparisonCards }
            } else {
                HStack(alignment: .top, spacing: 12) { comparisonCards }
            }
            MortgagePanel {
                Label(sheet == .strategies ? "结合现金流选择" : "没有适合所有人的还法", systemImage: "info.circle").font(.subheadline.weight(.medium))
                Text(sheet == .strategies ? "缩短年限通常更省利息；减少月供让每月压力更小。这里只比较贷款本身，未计入违约金、手续费或资金的其他用途，实际可选方式以银行规则为准。" : "等额本息方便稳定安排支出；等额本金前期月供更高，总利息更少。要结合自己的现金流，不是只看总利息。")
                    .font(.caption).foregroundStyle(MortgageStyle.secondary)
            }
        }
    }
    private var comparisonCards: some View {
        Group {
            if sheet == .strategies {
                comparisonCard("term", title: "缩短年限")
                comparisonCard("payment", title: "减少月供")
            } else {
                comparisonCard("equal", title: "等额本息")
                comparisonCard("principal", title: "等额本金")
            }
        }
    }
    private func comparisonCard(_ key: String, title: String) -> some View {
        let strategies = sheet == .strategies
        let chosen = strategies ? presentation.strategy == key : presentation.draft["method"].text == key
        let result = presentation.calculation[key]
        let alternative = MortgagePresentation(kind: presentation.kind, draft: presentation.draft, calculation: presentation.calculation, prepayment: strategies, strategy: key)
        let payment = strategies ? alternative.payment : result["rows"][0]["payment"]
        return MortgagePanel(padding: 15) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(chosen ? MortgageStyle.accent : MortgageStyle.secondary).accessibilityHidden(true)
                Text(title).font(.headline)
                Text(chosen ? "当前选择" : "可选方案").font(.caption2).foregroundStyle(chosen ? MortgageStyle.accent : MortgageStyle.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(strategies ? "提前还款后月供" : key == "principal" ? "首月还款" : "每月还款").font(.caption).foregroundStyle(MortgageStyle.secondary)
                Text("¥ " + MortgageDisplay.money(payment)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
            }
            Divider().overlay(MortgageStyle.line)
            if strategies {
                comparisonMetric("节省利息", value: MortgageDisplay.wan(presentation.savedInterest(for: key)) + " 万元")
                comparisonMetric(alternative.monthsTitle, value: String(presentation.savedMonths(for: key)) + " 个月")
            } else {
                comparisonMetric("利息总额", value: MortgageDisplay.wan(result["interest"]) + " 万元")
                comparisonMetric("还款节奏", value: key == "equal" ? "每月相同" : "逐月递减")
            }
            comparisonMetric(presentation.isCurrent ? "未来还款" : "累计还款", value: MortgageDisplay.wan(presentation.repaymentTotal(for: key)) + " 万元")
            Button {
                if strategies { selectStrategy(key) } else { selectMethod(key) }
                dismiss()
            } label: {
                Text(chosen ? "已选用" : "选用此方式").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    .background(MortgageStyle.tint, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).foregroundStyle(MortgageStyle.accent).accessibilityIdentifier("mortgage-choose-" + key)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func comparisonMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(MortgageStyle.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
    private var scheduleRows: [JSONValue] {
        sheet == .history ? presentation.calculation["parts"][contract]["history"].array : presentation.calculation[scheduleKey]["rows"].array
    }
    private var schedule: some View {
        VStack(alignment: .leading, spacing: 18) {
            if sheet == .history {
                Picker("合同", selection: $contract) {
                    ForEach(presentation.calculation["parts"].array.indices, id: \.self) { index in Text("合同 \(index + 1)").tag(index) }
                }.pickerStyle(.segmented)
            } else {
                Picker("还款计划", selection: $scheduleKey) {
                    ForEach(["base", "term", "payment"].filter { !presentation.calculation[$0].isNull }, id: \.self) { key in
                        Text(key == "base" ? "原还款计划" : key == "term" ? "缩短年限" : "减少月供").tag(key)
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("mortgage-schedule-plan")
            }
            Picker("明细粒度", selection: $monthly) { Text("按年汇总").tag(false); Text("逐月明细").tag(true) }.pickerStyle(.segmented)
            Text("共 \(scheduleRows.count) 期 · 金额单位：元").font(.caption).foregroundStyle(MortgageStyle.secondary)
            if sheet == .schedule && presentation.isCurrent && scheduleKey != "base" && presentation.after == 0 {
                Label("现在提前还的金额发生在未来第一期之前，不计入下方逐期列表；汇总的未来还款包含这笔本金。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(MortgageStyle.secondary)
            }
            if scheduleRows.isEmpty {
                Text(sheet == .history ? "这份合同尚无已还期次。" : "该还款计划没有待还期次。").font(.subheadline).foregroundStyle(MortgageStyle.secondary)
            } else if monthly {
                LazyVStack(spacing: 12) {
                    ForEach(Array(scheduleRows.enumerated()), id: \.offset) { _, row in MortgagePanel { monthlyRow(row) } }
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(Array(stride(from: 0, to: scheduleRows.count, by: 12)), id: \.self) { start in
                        year(Array(scheduleRows.dropFirst(start).prefix(12)), number: start / 12 + 1)
                    }
                }
            }
            Text("按月计息、每期四舍五入到分，末期收齐尾差；与银行按天拆分计息可能有差异。")
                .font(.caption).foregroundStyle(MortgageStyle.secondary)
        }
    }
    private func year(_ rows: [JSONValue], number: Int) -> some View {
        let paid = rows.reduce(0) { $0 + $1["payment"].double + $1["prepay"].double }
        let interest = rows.reduce(0) { $0 + $1["interest"].double }
        let principal = rows.reduce(0) { $0 + $1["principal"].double + $1["prepay"].double }
        return MortgagePanel {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in monthlyRow(row); Divider().overlay(MortgageStyle.line) }
                }.padding(.top, 14)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("第 \(number) 年").font(.headline)
                    Text("合计还款 " + MortgageDisplay.money(.number(paid))).font(.subheadline).foregroundStyle(MortgageStyle.text).monospacedDigit()
                }
            }
            LabeledContent("本金（含提前还款）", value: MortgageDisplay.money(.number(principal)))
            LabeledContent("利息", value: MortgageDisplay.money(.number(interest)))
            LabeledContent("年末剩余本金", value: MortgageDisplay.money(rows.last?["balance"] ?? .null))
        }.font(.caption).monospacedDigit()
    }
    private func monthlyRow(_ row: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第 \(row["n"].int) 期").font(.subheadline.weight(.semibold))
                Spacer()
                Text(row["date"].text).font(.caption).foregroundStyle(MortgageStyle.secondary)
            }
            LabeledContent("常规月供", value: MortgageDisplay.money(row["payment"]))
            LabeledContent("本金", value: MortgageDisplay.money(row["principal"]))
            LabeledContent("利息", value: MortgageDisplay.money(row["interest"]))
            if row["prepay"].double > 0 { LabeledContent("另提前还款", value: MortgageDisplay.money(row["prepay"])) }
            LabeledContent("剩余本金", value: MortgageDisplay.money(row["balance"]))
        }.font(.caption).monospacedDigit().accessibilityElement(children: .contain)
    }
    private var chartData: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("与曲线使用相同数据，每年取一个期次；金额单位：万元。")
                .font(.caption).foregroundStyle(MortgageStyle.secondary)
            LazyVStack(spacing: 12) {
                ForEach(presentation.chartDataMonths, id: \.self) { month in
                    MortgagePanel {
                        Text(month == 0 ? "还款起点" : "第 \(month) 期 / \(MortgageDisplay.number(Double(month) / 12, decimals: 1)) 年").font(.subheadline.weight(.semibold))
                        ForEach(presentation.chartSeries) { series in
                            LabeledContent(series.title, value: series.balance(at: month).map { MortgageDisplay.wan(.number($0)) } ?? "—")
                                .font(.subheadline).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            explanation("每期怎么算", detail: "月利率 = 年利率 ÷ 12；每期利息 = 剩余本金 × 月利率。每期四舍五入到分，末期收齐尾差。计算使用与网页一致的本机计算引擎。")
            explanation("提前还款", detail: "记在所选期次正常还款之后。缩短年限保留原月供或每期本金，减少月供保留剩余期数。组合贷只调整所选合同，所选贷款缩短不一定代表整笔组合贷更早结清。")
            explanation("我的房贷", detail: "按合同、历史利率和已发生的提前还款逐期计算。LPR 重定价使用重定价月份之前公布的利率，未来利率按现有利率表沿用；也可手填下一次 LPR 做情景测算。")
            explanation("与银行可能不同", detail: "银行在利率变化月份可能按天拆分计息，这里按月计算。可用银行 App 显示的剩余本金校准。未计入违约金、手续费、保险与其他购房成本。")
            explanation("数据与方案", detail: "计算在本机完成。未保存修改保留在按服务器和账户隔离的本机草稿中；保存到云端后可在其他设备载入。云端冲突不会自动覆盖本机草稿。")
            if !presentation.calculation["asOf"].text.isEmpty {
                Text("利率表截至 \(presentation.calculation["asOf"].text)，不是实时报价，可手动修改。")
                    .font(.caption).foregroundStyle(MortgageStyle.secondary)
            }
        }
    }
    private func explanation(_ title: String, detail: String) -> some View {
        MortgagePanel { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(MortgageStyle.secondary) }
    }
}
