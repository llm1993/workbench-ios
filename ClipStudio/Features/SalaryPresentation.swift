import Foundation

enum SalaryScene: String, CaseIterable, Identifiable {
    case calc, slip, compare
    var id: String { rawValue }
    var title: String {
        switch self { case .calc: return "到手试算"; case .slip: return "工资条"; case .compare: return "对比" }
    }
    var symbol: String {
        switch self { case .calc: return "yensign.circle"; case .slip: return "list.bullet.rectangle"; case .compare: return "arrow.left.arrow.right" }
    }
    var selectedSymbol: String {
        switch self { case .calc: return "yensign.circle.fill"; case .slip: return "list.bullet.rectangle.fill"; case .compare: return "arrow.left.arrow.right.circle.fill" }
    }
    var heading: String {
        switch self { case .calc: return "到手试算"; case .slip: return "逐月工资条"; case .compare: return "算清差别" }
    }
    var subtitle: String {
        switch self {
        case .calc: return "税前到到手，中间到底少了什么。"
        case .slip: return "每一笔扣款都对得上，个税能看到算式。"
        case .compare: return "年终奖怎么发、offer 怎么选、涨薪能落袋多少。"
        }
    }
}

enum SalarySheet: String, Identifiable {
    case plans, explain, standards, cities, year, month, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plans: return "示例方案"
        case .explain: return "怎么算的"
        case .standards: return "专项附加扣除标准"
        case .cities: return "城市预设（示例值）"
        case .year: return "全年逐月明细"
        case .month: return "选择月份"
        case .export: return "导出工资条"
        }
    }
}

/// Semantic money-flow slots; the view maps them to the payslip palette.
enum SalaryFlowKind: String, CaseIterable, Identifiable {
    case gross, social, fund, tax, other, net
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gross: return "税前"; case .social: return "社保"; case .fund: return "公积金"
        case .tax: return "个税"; case .other: return "其他"; case .net: return "到手"
        }
    }
}

struct SalaryLine: Identifiable, Equatable {
    let id: String
    let title: String
    var note: String = ""
    let amount: Double
    var kind: SalaryFlowKind = .gross
    var emphasis = false
    var muted = false
}

struct SalaryMetric: Identifiable, Equatable {
    let title: String
    let value: String
    let unit: String
    var id: String { title }
}

struct SalaryShare: Identifiable, Equatable {
    let kind: SalaryFlowKind
    let value: Double
    let ratio: Double
    var id: String { kind.rawValue }
    var title: String { kind.title }
}

struct SalaryBar: Identifiable, Equatable {
    let title: String
    let value: String
    let ratio: Double
    let kind: SalaryFlowKind
    var id: String { title }
}

struct SalaryChartBar: Identifiable, Equatable {
    let month: Int
    let active: Bool
    let net: Double
    let fund: Double
    let social: Double
    let tax: Double
    let other: Double
    let jumpTo: Double?
    var id: Int { month }
    var total: Double { net + fund + social + tax + other }
}

struct SalaryBonusCard: Identifiable, Equatable {
    let id: String
    let title: String
    let tax: Double
    let bonusTax: Double
    let net: Double
    let best: Bool
    var salaryTax: Double { tax - bonusTax }
}

enum SalaryDisplay {
    static func number(_ value: Double, decimals: Int = 0) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.locale(Locale(identifier: "zh_CN")).precision(.fractionLength(0...decimals)))
    }
    static func money(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.locale(Locale(identifier: "zh_CN")).precision(.fractionLength(2)))
    }
    static func whole(_ value: Double) -> String { number(value.rounded()) }
    static func wan(_ value: Double) -> String { number(value / 10_000, decimals: 2) }
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return (value * 100).formatted(.number.locale(Locale(identifier: "zh_CN")).precision(.fractionLength(1))) + "%"
    }
    static func rate(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func compact(_ value: Double) -> String {
        String(format: "%.1fk", value / 1000)
    }
    static func signed(_ value: Double) -> String {
        (value < 0 ? "−" : "") + money(abs(value))
    }
}

struct SalaryPresentation {
    let result: JSONValue
    let tables: JSONValue
    let month: Int
    var withBonus = true

    var main: JSONValue { result["main"] }
    var rows: [JSONValue] { main["rows"].array }
    var row: JSONValue { rows.indices.contains(month - 1) ? rows[month - 1] : .null }
    var city: JSONValue { result["city"] }
    var insurance: JSONValue { result["insurance"] }
    var special: JSONValue { result["special"] }
    var active: Bool { row["active"].flag }
    var net: Double { row["net"].double }
    var grossTotal: Double { row["gross"].double + row["bonus"].double }
    var hasBonus: Bool { result["bonusCompare"]["hasBonus"].flag }
    var bonusModeTitle: String { result["bonusMode"].text == "separate" ? "单独计税" : "并入综合所得" }

    var monthTitle: String { "\(month) 月到手" }
    var badge: String {
        if !active { return "未入职" }
        if row["bonus"].double > 0 { return "含年终奖" }
        if !row["jump"].isNull { return "本月跳档 \(SalaryDisplay.rate(row["rate"].double))" }
        return "税率档 \(SalaryDisplay.rate(row["rate"].double))"
    }
    var badgeIsJump: Bool { active && !row["jump"].isNull }
    var summary: String {
        let rate = grossTotal > 0 ? SalaryDisplay.percent(net / grossTotal) : "—"
        return "\(city["name"].text) · 税前 \(SalaryDisplay.whole(grossTotal))  /  到手率 \(rate)  /  专项附加 \(SalaryDisplay.whole(special["total"].double))/月"
    }

    var flow: [SalaryLine] {
        var lines = [SalaryLine(id: "gross", title: "税前月薪", amount: row["gross"].double)]
        if row["bonus"].double > 0 {
            lines.append(SalaryLine(id: "bonus", title: "年终奖（\(bonusModeTitle)）", amount: row["bonus"].double))
        }
        lines.append(SalaryLine(id: "social", title: "社保个人部分", amount: -row["social"].double, kind: .social))
        lines.append(SalaryLine(id: "fund", title: "公积金个人部分", note: "进你的账户", amount: -row["fund"].double, kind: .fund))
        lines.append(SalaryLine(id: "tax", title: "个人所得税", amount: -row["taxTotal"].double, kind: .tax))
        if row["afterTax"].double > 0 {
            lines.append(SalaryLine(id: "after", title: "税后扣款", amount: -row["afterTax"].double, kind: .other))
        }
        lines.append(SalaryLine(id: "net", title: "实发到手", amount: net, kind: .net, emphasis: true))
        return lines
    }

    var shares: [SalaryShare] {
        let parts: [(SalaryFlowKind, Double)] = [(.net, max(0, net)), (.fund, row["fund"].double), (.social, row["social"].double),
                                                 (.tax, row["taxTotal"].double), (.other, row["afterTax"].double)]
        let sum = parts.reduce(0) { $0 + $1.1 }
        guard sum > 0 else { return [] }
        return parts.filter { $0.1 > 0 }.map { SalaryShare(kind: $0.0, value: $0.1, ratio: $0.1 / sum) }
    }
    var shareSummary: String {
        shares.map { "\($0.title) \(SalaryDisplay.percent($0.ratio))" }.joined(separator: "，")
    }

    var metrics: [SalaryMetric] {
        [SalaryMetric(title: "全年到手", value: SalaryDisplay.wan(main["net"].double), unit: "万元"),
         SalaryMetric(title: "月均到手", value: SalaryDisplay.whole(main["avgNet"].double), unit: "元"),
         SalaryMetric(title: "全年个税", value: SalaryDisplay.whole(main["taxTotal"].double), unit: "元")]
    }

    var insight: String {
        let compare = result["bonusCompare"]
        if hasBonus {
            let best = compare["best"].text == "separate" ? "单独计税" : "并入综合所得"
            return "年终奖 \(SalaryDisplay.whole(main["bonus"].double)) 元，\(best)比另一种少交 \(SalaryDisplay.whole(compare["saving"].double)) 元。"
        }
        let raise = result["raise"]
        return "月薪每加 1,000 元，全年实际多到手 \(SalaryDisplay.whole(raise["yearGain"].double)) 元，落袋 \(SalaryDisplay.percent(raise["keepRate"].double))。"
    }
    var insightAction: String { hasBonus ? "看两种算法差多少" : "看涨薪与 offer 对比" }

    var notices: [String] {
        var warnings: [String] = []
        if active && net < 0 { warnings.append("社保按下限托底后已超过月薪，本月到手为负，实际请与 HR 确认缴纳口径。") }
        if insurance["capped"].flag { warnings.append("月薪高于\(city["name"].text)社保基数上限，社保按 \(SalaryDisplay.whole(insurance["base"].double)) 封顶计算。") }
        if insurance["floored"].flag { warnings.append("月薪低于\(city["name"].text)社保基数下限，社保按 \(SalaryDisplay.whole(insurance["base"].double)) 托底计算。") }
        return warnings
    }
    var invite: String {
        "当前方案全年到手 \(SalaryDisplay.wan(main["net"].double)) 万元，月均 \(SalaryDisplay.whole(main["avgNet"].double)) 元。"
    }

    // MARK: - 逐月工资条

    var receiptTitle: String { "\(month) 月工资条" }
    var receiptSubtitle: String {
        "\(city["name"].text) · 社保基数 \(SalaryDisplay.whole(insurance["base"].double)) · 公积金基数 \(SalaryDisplay.whole(insurance["fundBase"].double)) × \(SalaryDisplay.number(insurance["rate"].double, decimals: 1))%"
    }
    var receiptBadge: String { !active ? "未入职" : row["bonus"].double > 0 ? "含年终奖" : "在职" }

    var income: [SalaryLine] {
        var lines = [SalaryLine(id: "salary", title: "月薪（应发）", amount: row["gross"].double)]
        if row["bonus"].double > 0 { lines.append(SalaryLine(id: "bonus", title: "全年一次性奖金", amount: row["bonus"].double)) }
        lines.append(SalaryLine(id: "sum", title: "应发合计", amount: grossTotal, emphasis: true))
        return lines
    }

    var deductions: [SalaryLine] {
        let items = insurance["items"].array
        let medicalNote = SalaryDisplay.number(city["medical"].double, decimals: 1) + "%"
            + (city["medicalFix"].double > 0 ? " + \(SalaryDisplay.whole(city["medicalFix"].double)) 元" : "")
        let candidates = [
            SalaryLine(id: "pension", title: "养老保险", note: "8%", amount: active ? items[0]["value"].double : 0, kind: .social),
            SalaryLine(id: "medical", title: "医疗保险", note: medicalNote, amount: active ? items[1]["value"].double : 0, kind: .social),
            SalaryLine(id: "unemployment", title: "失业保险", note: "0.5%", amount: active ? items[2]["value"].double : 0, kind: .social),
            SalaryLine(id: "fund", title: "住房公积金", note: SalaryDisplay.number(insurance["rate"].double, decimals: 1) + "%", amount: row["fund"].double, kind: .fund),
            SalaryLine(id: "otherPre", title: "其他税前扣除", note: "只减应纳税所得额", amount: row["otherPre"].double, kind: .other),
            SalaryLine(id: "tax", title: "个人所得税（工资）", note: "预扣 \(SalaryDisplay.rate(row["rate"].double)) 档", amount: row["tax"].double, kind: .tax),
            SalaryLine(id: "bonusTax", title: "个人所得税（年终奖）", note: result["bonusMode"].text == "separate" ? "单独计税" : "已并入上行", amount: row["bonusTax"].double, kind: .tax),
            SalaryLine(id: "afterTax", title: "税后扣款", note: "工会费 / 餐费等", amount: row["afterTax"].double, kind: .other)
        ].filter { $0.amount > 0 }
        var lines = candidates.isEmpty ? [SalaryLine(id: "none", title: "本月无扣款", amount: 0, muted: true)] : candidates
        lines.append(SalaryLine(id: "sum", title: "扣除合计", amount: -deductionTotal, kind: .tax, emphasis: true))
        return lines
    }
    var deductionTotal: Double {
        row["social"].double + row["fund"].double + row["otherPre"].double + row["taxTotal"].double + row["afterTax"].double
    }

    var employer: [SalaryLine] {
        let items = insurance["items"].array
        let lines = [
            SalaryLine(id: "er-pension", title: "养老保险", note: "16%", amount: items[0]["er"].double),
            SalaryLine(id: "er-medical", title: "医疗保险（含生育）", note: SalaryDisplay.number(city["erMedical"].double, decimals: 2) + "%", amount: items[1]["er"].double),
            SalaryLine(id: "er-unemployment", title: "失业保险", note: "0.5%", amount: items[2]["er"].double),
            SalaryLine(id: "er-injury", title: "工伤保险", note: SalaryDisplay.number(city["injury"].double, decimals: 2) + "%", amount: items[3]["er"].double),
            SalaryLine(id: "er-fund", title: "住房公积金", note: SalaryDisplay.number(insurance["rate"].double, decimals: 1) + "%", amount: items[4]["er"].double, kind: .fund)
        ].map { SalaryLine(id: $0.id, title: $0.title, note: $0.note, amount: active ? $0.amount : 0, kind: $0.kind) }
        return lines + [SalaryLine(id: "er-sum", title: "单位缴纳合计", amount: employerTotal, emphasis: true),
                        SalaryLine(id: "er-cost", title: "公司为你付出的总成本", amount: employerCost, muted: true)]
    }
    var employerTotal: Double { active ? insurance["employer"].double : 0 }
    var employerCost: Double { grossTotal + employerTotal }

    private func cumulative(_ key: String) -> Double {
        rows.prefix(month).reduce(0) { $0 + $1[key].double }
    }
    var activeMonths: Int { rows.prefix(month).filter { $0["active"].flag }.count }
    var previouslyPaid: Double { row["cumTax"].double - row["tax"].double }

    var taxRatePill: String {
        active ? "\(SalaryDisplay.rate(row["rate"].double)) 档 · 速算 \(SalaryDisplay.whole(row["quick"].double))" : "未入职"
    }
    var taxSteps: [SalaryLine] {
        let standard = tables["standard"].double
        return [
            SalaryLine(id: "cumIncome", title: "累计收入", amount: row["cumIncome"].double, muted: true),
            SalaryLine(id: "cumStandard", title: "累计减除费用（\(SalaryDisplay.whole(standard)) × \(activeMonths) 个月）", amount: -standard * Double(activeMonths), muted: true),
            SalaryLine(id: "cumInsurance", title: "累计三险一金", amount: -(cumulative("social") + cumulative("fund")), muted: true),
            SalaryLine(id: "cumSpecial", title: "累计专项附加扣除", amount: -cumulative("special"), muted: true),
            SalaryLine(id: "cumOther", title: "累计其他税前扣除", amount: -cumulative("otherPre"), muted: true),
            SalaryLine(id: "cumTaxable", title: "累计应纳税所得额", amount: row["cumTaxable"].double, emphasis: true),
            SalaryLine(id: "cumTax", title: "累计应纳税额", amount: row["cumTax"].double),
            SalaryLine(id: "prevPaid", title: "此前已预扣", amount: previouslyPaid > 0 ? -previouslyPaid : 0, muted: true),
            SalaryLine(id: "tax", title: "本月应预扣", amount: row["tax"].double, kind: .tax, emphasis: true)
        ]
    }
    var taxFormula: String {
        guard active else { return "本月尚未入职，不参与累计预扣。入职当月起重新从 3% 档累计。" }
        var text = "本月预扣 = 累计应纳税所得额 \(SalaryDisplay.money(row["cumTaxable"].double)) × \(SalaryDisplay.rate(row["rate"].double)) − 速算扣除数 \(SalaryDisplay.whole(row["quick"].double)) − 已预扣 \(SalaryDisplay.money(previouslyPaid)) = \(SalaryDisplay.money(row["tax"].double))"
        if row["bonusTax"].double > 0 {
            let bonus = row["bonus"].double
            text += "\n年终奖单独计税 = \(SalaryDisplay.money(bonus)) ÷ 12 = \(SalaryDisplay.money(bonus / 12)) → 适用 \(SalaryDisplay.rate(bonusRate(bonus))) 档，税额 \(SalaryDisplay.money(row["bonusTax"].double))"
        }
        return text
    }
    func bonusRate(_ bonus: Double) -> Double {
        let table = tables["month"].array
        return table.first { !$0[0].isNull && bonus / 12 <= $0[0].double }?[1].double ?? 0.45
    }

    // MARK: - 对比

    var bonusCards: [SalaryBonusCard] {
        let compare = result["bonusCompare"]
        return ["separate", "merged"].map { key in
            let item = compare[key]
            return SalaryBonusCard(id: key, title: key == "separate" ? "单独计税" : "并入综合所得",
                                   tax: item["tax"].double, bonusTax: item["bonusTax"].double, net: item["net"].double,
                                   best: hasBonus && compare["best"].text == key)
        }
    }
    var bonusDelta: String {
        guard hasBonus else { return "还没有填年终奖。填上金额后，这里会直接告诉你哪种算法更省。" }
        let compare = result["bonusCompare"]
        let best = compare["best"].text == "separate" ? "单独计税" : "并入综合所得"
        let saving = compare["saving"].double
        let tail = result["auto"].flag ? "当前已自动择优。" : "当前手动选了\(bonusModeTitle)。"
        return "选 \(best)，全年少交 ¥\(SalaryDisplay.whole(saving))，摊到每月多拿 ¥\(SalaryDisplay.whole(saving / 12))。\(tail)"
    }
    static func trapText(_ trap: JSONValue, bonus: Double) -> String {
        switch trap["state"].text {
        case "blind":
            return "落在跳档盲区：发 \(SalaryDisplay.whole(bonus)) 元的到手，比发 \(SalaryDisplay.whole(trap["edge"].double)) 元还少 \(SalaryDisplay.whole(trap["loss"].double)) 元。要么降到 \(SalaryDisplay.whole(trap["edge"].double))，要么至少发到 \(SalaryDisplay.whole(trap["fix"].double))。"
        case "below":
            return "当前不在跳档盲区。下一个临界点是 \(SalaryDisplay.whole(trap["next"].double)) 元，跨过后税率会从 \(SalaryDisplay.rate(trap["fromRate"].double)) 跳到 \(SalaryDisplay.rate(trap["toRate"].double))。"
        case "top":
            return "当前不在跳档盲区，已适用最高 45% 档。"
        default:
            return "年终奖单独计税一年只能用一次；季度奖、绩效奖需并入综合所得。"
        }
    }

    func raiseMetrics(_ marginal: JSONValue, delta: Double) -> [SalaryMetric] {
        [SalaryMetric(title: "全年多到手", value: SalaryDisplay.whole(marginal["yearGain"].double), unit: "元"),
         SalaryMetric(title: "月均多到手", value: SalaryDisplay.whole(marginal["monthGain"].double), unit: "元"),
         SalaryMetric(title: "被吃掉", value: SalaryDisplay.whole(delta * 12 - marginal["yearGain"].double), unit: "元")]
    }

    var yearBars: [SalaryBar] {
        let gross = max(1, main["gross"].double + main["bonus"].double)
        let items: [(String, Double, SalaryFlowKind)] = [
            ("到手（打进工资卡）", main["net"].double, .net), ("公积金个人部分", main["fund"].double, .fund),
            ("社保个人部分", main["social"].double, .social), ("个人所得税", main["taxTotal"].double, .tax),
            ("税后扣款", main["afterTax"].double, .other)
        ]
        return items.filter { $0.1 > 0 }.map {
            SalaryBar(title: $0.0, value: "¥\(SalaryDisplay.whole($0.1)) · \(SalaryDisplay.percent($0.1 / gross))", ratio: $0.1 / gross, kind: $0.2)
        }
    }
    var yearNote: String {
        "单位另为你缴纳五险一金 ¥\(SalaryDisplay.whole(result["cost"]["employer"].double))，公司总成本 ¥\(SalaryDisplay.whole(result["cost"]["total"].double))。全年综合税负 \(SalaryDisplay.percent(result["effectiveRate"].double))，到手率 \(SalaryDisplay.percent(result["netRate"].double))。公积金个人部分虽从工资里扣，但仍进你的账户。"
    }

    // MARK: - 图表

    var chartBars: [SalaryChartBar] {
        rows.map { item in
            let bonusNet = item["bonus"].double - item["bonusTax"].double
            return SalaryChartBar(month: item["month"].int, active: item["active"].flag,
                                  net: max(0, item["net"].double - (withBonus ? 0 : bonusNet)),
                                  fund: item["fund"].double, social: item["social"].double,
                                  tax: item["taxTotal"].double - (withBonus ? 0 : item["bonusTax"].double),
                                  other: item["afterTax"].double,
                                  jumpTo: item["jump"].isNull ? nil : item["jump"]["to"].double)
        }
    }
    var chartUnit: Double { (chartBars.map(\.total).max() ?? 0) >= 20_000 ? 10_000 : 1_000 }
    var chartUnitTitle: String { chartUnit == 10_000 ? "万元" : "千元" }
    var bonusMonth: Int? { rows.first { $0["bonus"].double > 0 }?["month"].int }
    var chartSubtitle: String {
        if withBonus, let month = bonusMonth { return "含 \(month) 月发放的年终奖，纵轴按全年峰值缩放。" }
        return "累计预扣预缴：收入累计越高，税率跳档后到手越少。"
    }
    var chartReadTitle: String { "\(month) 月\(active ? "" : "（未入职）") · 到手" }
    var chartReadValue: Double { chartBars.indices.contains(month - 1) ? chartBars[month - 1].net : 0 }

    // MARK: - 文本导出

    func slipText(trap: JSONValue) -> String {
        var lines = ["\(receiptTitle)（\(receiptBadge)）", receiptSubtitle, "", "应发项目"]
        lines += income.map { "\($0.title)：\(SalaryDisplay.money($0.amount))" }
        lines += ["", "个人扣除"]
        lines += deductions.map { "\($0.title)\($0.note.isEmpty ? "" : "（\($0.note)）")：\(SalaryDisplay.signed($0.amount))" }
        lines += ["", "实发到手：¥\(SalaryDisplay.money(net))", "", "本月个税怎么来的"]
        lines += taxSteps.map { "\($0.title)：\(SalaryDisplay.signed($0.amount))" }
        lines += ["", taxFormula]
        if hasBonus { lines += ["", "年终奖两种算法", bonusDelta, SalaryPresentation.trapText(trap, bonus: main["bonus"].double)] }
        lines += ["", "城市社保 / 公积金预设为示例值，结果仅供参考，实际以工资条与当地社保年度公布数据为准。"]
        return lines.joined(separator: "\n")
    }
}
extension SalaryPresentation {
    static func offerSubtitle(_ result: JSONValue) -> String {
        result["city"]["name"].text + " · 月均 " + SalaryDisplay.whole(result["main"]["avgNet"].double)
    }
    static func offerDelta(_ a: JSONValue, _ b: JSONValue) -> String {
        let left = a["main"], right = b["main"]
        let diff = right["net"].double - left["net"].double
        let grossDiff = (right["gross"].double + right["bonus"].double) - (left["gross"].double + left["bonus"].double)
        guard abs(diff) >= 1 else { return "两份 offer 全年到手基本一样，可以比公积金比例、通勤和成长空间。" }
        let landing = grossDiff != 0 ? SalaryDisplay.percent(abs(diff / grossDiff)) : "—"
        return "B 比 A 全年\(diff > 0 ? "多" : "少")到手 ¥\(SalaryDisplay.whole(abs(diff)))（月均 \(SalaryDisplay.whole(abs(diff) / 12))）。"
            + "税前差 \(SalaryDisplay.whole(abs(grossDiff))) 元，实际落袋 \(landing)。"
            + "公积金另有 B \(SalaryDisplay.wan(right["fund"].double)) 万 / A \(SalaryDisplay.wan(left["fund"].double)) 万进个人账户。"
    }
    static func offerBars(_ a: JSONValue, _ b: JSONValue) -> [SalaryBar] {
        let left = a["main"]["net"].double, right = b["main"]["net"].double
        let peak = max(left, right, 1)
        return [SalaryBar(title: "offer A 全年到手", value: "¥" + SalaryDisplay.whole(left), ratio: left / peak, kind: .gross),
                SalaryBar(title: "offer B 全年到手", value: "¥" + SalaryDisplay.whole(right), ratio: right / peak, kind: .net)]
    }
}
