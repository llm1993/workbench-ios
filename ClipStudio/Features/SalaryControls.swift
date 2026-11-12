import SwiftUI

struct SalaryControls: View {
    let draft: JSONValue
    let cities: [JSONValue]
    let insurance: JSONValue
    let special: JSONValue
    let bonusModeTitle: String
    let edit: (String, JSONValue) -> Void
    let random: () -> Void
    let reset: () -> Void
    let export: () -> Void
    let standards: () -> Void
    let cityInfo: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var cityOptions: [SalaryOption] { cities.map { SalaryOption(id: $0["key"].text, title: $0["name"].text) } }
    private var monthOptions: [SalaryOption] { (1...12).map { SalaryOption(id: String($0), title: "\($0) 月") } }
    private var startOptions: [SalaryOption] { (1...12).map { SalaryOption(id: String($0), title: $0 == 1 ? "1 月（全年在职）" : "\($0) 月") } }
    private var baseOptions: [SalaryOption] { [SalaryOption(id: "auto", title: "按月薪"), SalaryOption(id: "floor", title: "按下限"), SalaryOption(id: "custom", title: "自己填")] }

    var body: some View {
        SalaryPanel {
            ViewThatFits(in: .horizontal) {
                HStack { Label("测算参数", systemImage: "slider.horizontal.3").font(.headline); Spacer(minLength: 8); tools }
                VStack(alignment: .leading, spacing: 12) { Label("测算参数", systemImage: "slider.horizontal.3").font(.headline); tools }
            }
            Text("改一个数，上面立刻重算 · 全部为示例参数").font(.caption).foregroundStyle(SalaryStyle.secondary)
            salary
            Divider().overlay(SalaryStyle.line)
            insuranceBase
            fund
            Divider().overlay(SalaryStyle.line)
            deductions
            Divider().overlay(SalaryStyle.line)
            bonus
            Divider().overlay(SalaryStyle.line)
            others
        }.accessibilityIdentifier("salary-controls")
    }

    private var tools: some View {
        HStack(spacing: 8) {
            SalaryActionChip(title: "换一组示例", symbol: "dice", action: random, identifier: "salary-random")
            SalaryActionChip(title: "恢复默认", symbol: "arrow.counterclockwise", action: reset, identifier: "salary-reset")
            SalaryActionChip(title: "导出工资条", symbol: "square.and.arrow.up", action: export, identifier: "salary-export")
        }
    }

    private var salary: some View {
        VStack(alignment: .leading, spacing: 14) {
            if typeSize.isAccessibilitySize {
                SalaryMenu(title: "参保城市", value: draft["city"].text, options: cityOptions, select: { edit("city", .string($0)) }, identifier: "salary-city")
                SalaryNumberField(title: "税前月薪", value: text("gross"), unit: "元", identifier: "salary-gross")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    SalaryMenu(title: "参保城市", value: draft["city"].text, options: cityOptions, select: { edit("city", .string($0)) }, identifier: "salary-city")
                    SalaryNumberField(title: "税前月薪", value: text("gross"), unit: "元", identifier: "salary-gross")
                }
            }
            SalarySlider(title: "税前月薪", value: number("gross"), range: 3000...120000, step: 500,
                         readout: "¥" + SalaryDisplay.whole(draft["gross"].double), identifier: "salary-gross-slider")
            Button(action: cityInfo) {
                Label("城市社保预设是示例值，点这里看区间", systemImage: "info.circle").font(.caption2)
                    .foregroundStyle(SalaryStyle.secondary)
            }.buttonStyle(.plain).frame(minHeight: 32).accessibilityIdentifier("salary-city-info")
        }
    }

    private var insuranceBase: some View {
        VStack(alignment: .leading, spacing: 11) {
            SalarySubheading(title: "社保缴费基数", readout: "¥" + SalaryDisplay.whole(insurance["base"].double))
            SalarySegment(title: "社保基数口径", options: baseOptions, selection: option("baseMode"), identifier: "salary-base")
            if draft["baseMode"].text == "custom" {
                SalaryNumberField(title: "自定义社保基数", value: text("customBase"), unit: "元", identifier: "salary-custom-base")
            }
            if insurance["capped"].flag || insurance["floored"].flag {
                Text(insurance["capped"].flag ? "已按当地上限封顶。" : "已按当地下限托底。")
                    .font(.caption2).foregroundStyle(SalaryStyle.secondary)
            }
        }
    }

    private var fund: some View {
        VStack(alignment: .leading, spacing: 14) {
            SalarySlider(title: "公积金比例", value: number("fundRate"), range: 0...12, step: 0.5,
                         readout: SalaryDisplay.number(draft["fundRate"].double, decimals: 1) + "%", identifier: "salary-fund-rate")
            SalarySubheading(title: "公积金基数", readout: "¥" + SalaryDisplay.whole(insurance["fundBase"].double))
            SalarySegment(title: "公积金基数口径", options: baseOptions, selection: option("fundMode"), identifier: "salary-fund-base")
            if draft["fundMode"].text == "custom" {
                SalaryNumberField(title: "自定义公积金基数", value: text("customFundBase"), unit: "元", identifier: "salary-custom-fund")
            }
        }
    }

    private var deductions: some View {
        VStack(alignment: .leading, spacing: 14) {
            SalarySubheading(title: "专项附加扣除", readout: "¥" + SalaryDisplay.whole(special["total"].double) + "/月")
            VStack(alignment: .leading, spacing: 2) {
                SalaryStepper(title: "子女教育", value: draft["children"].int, change: { step("children", $0) }, identifier: "salary-children")
                Text("每孩 2,000 元/月").font(.caption2).foregroundStyle(SalaryStyle.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                SalaryStepper(title: "3 岁以下婴幼儿照护", value: draft["infants"].int, change: { step("infants", $0) }, identifier: "salary-infants")
                Text("每孩 2,000 元/月").font(.caption2).foregroundStyle(SalaryStyle.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("赡养老人").font(.subheadline.weight(.medium))
                SalarySegment(title: "赡养老人扣除",
                              options: [SalaryOption(id: "only", title: "独生 3,000"), SalaryOption(id: "share", title: "分摊 1,500"), SalaryOption(id: "none", title: "无")],
                              selection: option("elder"), identifier: "salary-elder")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("住房（二选一）").font(.subheadline.weight(.medium))
                SalarySegment(title: "住房扣除",
                              options: [SalaryOption(id: "loan", title: "房贷 1,000"), SalaryOption(id: "rent", title: "房租"), SalaryOption(id: "none", title: "无")],
                              selection: option("housing"), identifier: "salary-housing")
                if draft["housing"].text == "rent" {
                    SalaryMenu(title: "房租城市档位", value: String(draft["rentTier"].int),
                               options: [SalaryOption(id: "0", title: "直辖市 / 省会 1,500"), SalaryOption(id: "1", title: "人口超 100 万 1,100"), SalaryOption(id: "2", title: "不超 100 万 800")],
                               select: { edit("rentTier", .integer(Int($0) ?? 0)) }, identifier: "salary-rent-tier")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 8) { chips }
            }
            SalaryNumberField(title: "个人养老金（上限 1,000）", value: text("pension"), unit: "元/月", identifier: "salary-pension")
        }
    }

    @ViewBuilder private var chips: some View {
        SalaryToggleChip(title: "继续教育 400/月", selected: draft["study"].flag, action: { edit("study", .bool(!draft["study"].flag)) }, identifier: "salary-study")
        SalaryToggleChip(title: "扣除标准 ›", selected: false, action: standards, identifier: "salary-standards")
    }

    private var bonus: some View {
        VStack(alignment: .leading, spacing: 14) {
            if typeSize.isAccessibilitySize {
                SalaryNumberField(title: "年终奖", value: text("bonus"), unit: "元", identifier: "salary-bonus")
                SalaryMenu(title: "发放月份", value: String(draft["bonusMonth"].int), options: monthOptions,
                           select: { edit("bonusMonth", .integer(Int($0) ?? 12)) }, identifier: "salary-bonus-month")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    SalaryNumberField(title: "年终奖", value: text("bonus"), unit: "元", identifier: "salary-bonus")
                    SalaryMenu(title: "发放月份", value: String(draft["bonusMonth"].int), options: monthOptions,
                               select: { edit("bonusMonth", .integer(Int($0) ?? 12)) }, identifier: "salary-bonus-month")
                }
            }
            SalarySubheading(title: "年终奖计税方式", readout: bonusModeTitle)
            SalarySegment(title: "年终奖计税方式",
                          options: [SalaryOption(id: "auto", title: "自动择优"), SalaryOption(id: "separate", title: "单独计税"), SalaryOption(id: "merged", title: "并入综合")],
                          selection: option("bonusMode"), identifier: "salary-bonus-mode")
        }
    }

    private var others: some View {
        VStack(alignment: .leading, spacing: 14) {
            if typeSize.isAccessibilitySize {
                SalaryNumberField(title: "其他税前扣除", value: text("otherPre"), unit: "元", identifier: "salary-other-pre")
                SalaryNumberField(title: "税后扣款", value: text("afterTax"), unit: "元", identifier: "salary-after-tax")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    SalaryNumberField(title: "其他税前扣除", value: text("otherPre"), unit: "元", identifier: "salary-other-pre")
                    SalaryNumberField(title: "税后扣款", value: text("afterTax"), unit: "元", identifier: "salary-after-tax")
                }
            }
            SalaryMenu(title: "本年入职月份", value: String(draft["startMonth"].int), options: startOptions,
                       select: { edit("startMonth", .integer(Int($0) ?? 1)) }, identifier: "salary-start-month")
            Text("其他税前扣除如企业年金、税优健康险，只减应纳税所得额；税后扣款如工会费、餐费、宿舍费。")
                .font(.caption2).foregroundStyle(SalaryStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { draft[key].text }, set: { edit(key, .string($0)) })
    }
    private func number(_ key: String) -> Binding<Double> {
        Binding(get: { draft[key].double }, set: { edit(key, .number($0)) })
    }
    private func option(_ key: String) -> Binding<String> {
        Binding(get: { draft[key].text }, set: { edit(key, .string($0)) })
    }
    private func step(_ key: String, _ delta: Int) {
        edit(key, .integer(min(6, max(0, draft[key].int + delta))))
    }
}