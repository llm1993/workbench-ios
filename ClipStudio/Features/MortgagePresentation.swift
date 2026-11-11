import Foundation

enum MortgageScene: String, CaseIterable, Identifiable {
    case trial, current, prepayment
    var id: String { rawValue }
    var title: String {
        switch self { case .trial: return "买房试算"; case .current: return "我的房贷"; case .prepayment: return "提前还款" }
    }
    var symbol: String {
        switch self { case .trial: return "calculator"; case .current: return "house"; case .prepayment: return "wallet.bifold" }
    }
    var selectedSymbol: String {
        switch self { case .trial: return "calculator.fill"; case .current: return "house.fill"; case .prepayment: return "wallet.bifold.fill" }
    }
    var subtitle: String {
        switch self {
        case .trial: return "算清每月开支，从容计划一个家。"
        case .current: return "从放款到结清，看清你的还款进度。"
        case .prepayment: return "少付多少利息，早多久还清。"
        }
    }
}

enum MortgageSheet: String, Identifiable {
    case methods, strategies, schedule, chartData, history, about
    var id: String { rawValue }
}

struct MortgageMetric: Identifiable, Equatable {
    let title: String
    let value: String
    let unit: String
    var id: String { title }
}

struct MortgageBalancePoint: Identifiable, Equatable {
    let month: Int
    let balance: Double
    let series: String
    var id: String { "\(series)-\(month)" }
}

struct MortgageBalanceSeries: Identifiable, Equatable {
    let id: String
    let title: String
    let slot: Int
    let points: [MortgageBalancePoint]
    func balance(at month: Int) -> Double? {
        guard let first = points.first else { return nil }
        if month <= first.month { return first.balance }
        if let last = points.last, month > last.month { return 0 }
        return points.last(where: { $0.month <= month })?.balance
    }
}

enum MortgageDisplay {
    static func number(_ value: Double, decimals: Int = 2) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.locale(Locale(identifier: "zh_CN")).precision(.fractionLength(0...decimals)))
    }
    static func money(_ value: JSONValue) -> String {
        guard let amount = value.numeric else { return "—" }
        return amount.formatted(.number.locale(Locale(identifier: "zh_CN")).precision(.fractionLength(2)))
    }
    static func wan(_ value: JSONValue) -> String {
        guard let amount = value.numeric else { return "—" }
        return number(amount / 10_000)
    }
    static func periods(_ years: JSONValue) -> String {
        guard let value = years.numeric else { return "—" }
        let months = (value * 12).rounded()
        guard months.isFinite, months >= 1, months <= 360 else { return "—" }
        return number(months, decimals: 0)
    }
    static func method(_ value: JSONValue) -> String { value.text == "principal" ? "等额本金" : "等额本息" }
    static func loanType(_ value: JSONValue) -> String {
        switch value.text { case "fund": return "公积金贷款"; case "combo": return "组合贷款"; default: return "商业贷款" }
    }
}

struct MortgagePresentation {
    let kind: String
    let draft: JSONValue
    let calculation: JSONValue
    var prepayment = false
    var strategy = "term"

    var isCurrent: Bool { kind == "current" }
    var hasPrepayment: Bool { !calculation["term"].isNull && !calculation["payment"].isNull }
    var resultKey: String { prepayment && hasPrepayment ? strategy : "base" }
    var result: JSONValue { calculation[resultKey] }
    var after: Int { max(0, calculation["after"].int) }
    var plannedPrepayment: JSONValue { isCurrent ? draft["extraAmount"] : draft["preAmount"] }
    var actualPrepayment: JSONValue {
        guard hasPrepayment else { return .null }
        if isCurrent && after == 0 {
            let target = min(max(0, draft["extraPart"].int), max(0, calculation["parts"].array.count - 1))
            let amount = max(0, min(plannedPrepayment.double * 10_000, calculation["parts"][target]["balance"].double))
            return .number((amount * 100).rounded() / 100)
        }
        return calculation[strategy]["rows"].array.first(where: { $0["n"].int == after })?["prepay"] ?? .number(0)
    }
    var payment: JSONValue {
        let rows = result["rows"].array
        let index = prepayment && hasPrepayment ? after : 0
        if rows.indices.contains(index) { return rows[index]["payment"] }
        return calculation.isNull ? .null : .number(0)
    }
    var paymentTitle: String {
        if prepayment { return "提前还款后月供" }
        if isCurrent { return "预计下期还款" }
        return draft["method"].text == "principal" ? "预计首月还款" : "预计每月还款"
    }
    var badge: String {
        if prepayment { return strategy == "term" ? "缩短年限" : "减少月供" }
        if isCurrent { return "按合同测算" }
        return draft["method"].text == "principal" ? "逐月递减" : "每月固定"
    }
    var metadata: [String] {
        if prepayment {
            var details = ["实际提前还 \(MortgageDisplay.wan(actualPrepayment)) 万元"]
            if let actual = actualPrepayment.numeric, abs(actual - plannedPrepayment.double * 10_000) > 0.01 {
                details.append("计划 \(MortgageDisplay.number(plannedPrepayment.double)) 万元")
            }
            return details + [after == 0 ? "现在还款" : "第 \(after) 期后", "第 \(after + 1) 期起"]
        }
        if isCurrent { return ["\(calculation["parts"].array.count) 笔合同", "未来 \(result["months"].int) 期", "含历史利率调整"] }
        let rate = draft["type"].text == "fund" ? draft["fundRate"].double : draft["lpr"].double + draft["bp"].double / 100
        return [MortgageDisplay.loanType(draft["type"]), "\(MortgageDisplay.wan(calculation["total"])) 万元", "\(draft["years"].text) 年", draft["type"].text == "combo" ? "分笔计息" : "年利率 \(MortgageDisplay.number(rate))%"]
    }
    func savedInterest(for key: String) -> JSONValue {
        guard let base = calculation["base"]["interest"].numeric, let interest = calculation[key]["interest"].numeric else { return .null }
        return .number(max(0, base - interest))
    }
    func savedMonths(for key: String) -> Int {
        if key == "term", !isCurrent, !calculation["savedMonths"].isNull { return max(0, calculation["savedMonths"].int) }
        return max(0, calculation["base"]["months"].int - calculation[key]["months"].int)
    }
    var monthsTitle: String {
        guard strategy == "term" else { return "提前还清" }
        if !isCurrent && calculation["parts"].array.count > 1 { return "目标贷款缩短" }
        if isCurrent && calculation["parts"].array.count > 1 { return "整体计划缩短" }
        return "提前还清"
    }
    func repaymentTotal(for key: String) -> JSONValue {
        guard let principal = calculation["total"].numeric, let interest = calculation[key]["interest"].numeric else { return .null }
        // Immediate prepayments are not included in the engine's future paid sum.
        return .number(principal + interest)
    }
    var metrics: [MortgageMetric] {
        if prepayment {
            return [MortgageMetric(title: "节省利息", value: MortgageDisplay.wan(savedInterest(for: resultKey)), unit: "万元"),
                    MortgageMetric(title: monthsTitle, value: String(savedMonths(for: resultKey)), unit: "个月"),
                    MortgageMetric(title: isCurrent ? "未来还款" : "累计还款", value: MortgageDisplay.wan(repaymentTotal(for: resultKey)), unit: "万元")]
        }
        if isCurrent {
            let paidInterest = calculation["parts"].array.reduce(0) { $0 + $1["paidInterest"].double }
            return [MortgageMetric(title: "剩余本金", value: MortgageDisplay.wan(calculation["total"]), unit: "万元"),
                    MortgageMetric(title: "已付利息", value: MortgageDisplay.wan(.number(paidInterest)), unit: "万元"),
                    MortgageMetric(title: "未来利息", value: MortgageDisplay.wan(result["interest"]), unit: "万元")]
        }
        return [MortgageMetric(title: "贷款总额", value: MortgageDisplay.wan(calculation["total"]), unit: "万元"),
                MortgageMetric(title: "利息总额", value: MortgageDisplay.wan(result["interest"]), unit: "万元"),
                MortgageMetric(title: "累计还款", value: MortgageDisplay.wan(repaymentTotal(for: "base")), unit: "万元")]
    }
    var insight: String {
        if prepayment {
            if !isCurrent && calculation["parts"].array.count > 1 && strategy == "term" { return "缩短的是所选贷款，组合贷整体结清时间可能不变。" }
            return strategy == "term" ? "月供或每期本金基本不变，更早还清所选贷款。" : "保留剩余期数，给每月开支留一点余地。"
        }
        if isCurrent { return "未来按现有利率表推算，可用银行剩余本金校准。" }
        let difference = calculation["equal"]["interest"].double - calculation["principal"]["interest"].double
        return "等额本金比等额本息，少付 \(MortgageDisplay.wan(.number(max(0, difference)))) 万元利息。"
    }
    var chartSeries: [MortgageBalanceSeries] {
        let keys: [(String, String)] = prepayment ? [("base", "原还款计划"), (strategy, "提前还款后")] : isCurrent ? [("base", "剩余本金")] : [("equal", "等额本息"), ("principal", "等额本金")]
        return keys.enumerated().compactMap { slot, pair in
            let (key, title) = pair
            guard !calculation[key].isNull, let total = calculation["total"].numeric else { return nil }
            let start = MortgageBalancePoint(month: 0, balance: total, series: key)
            var points = calculation[key]["rows"].array.compactMap { row -> MortgageBalancePoint? in
                guard let balance = row["balance"].numeric else { return nil }
                return MortgageBalancePoint(month: row["n"].int, balance: balance, series: key)
            }
            if prepayment && isCurrent && after == 0 && key != "base" {
                points.insert(MortgageBalancePoint(month: 0, balance: max(0, total - actualPrepayment.double), series: key), at: 0)
            } else { points.insert(start, at: 0) }
            return MortgageBalanceSeries(id: key, title: title, slot: slot, points: points)
        }
    }
    var chartMonths: Int { max(1, chartSeries.flatMap(\.points).map(\.month).max() ?? 1) }
    var chartDataMonths: [Int] {
        let last = chartMonths
        return Array(stride(from: 0, to: last, by: 12)) + [last]
    }
}
