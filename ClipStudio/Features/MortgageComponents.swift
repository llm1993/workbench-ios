import SwiftUI

enum MortgageStyle {
    static let background = Color.dynamic(light: 0xF6F5F0, dark: 0x171C19)
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x212823)
    static let input = Color.dynamic(light: 0xF5F5F0, dark: 0x2A332D)
    static let text = Color.dynamic(light: 0x263D32, dark: 0xEBF0E9)
    static let secondary = Color.dynamic(light: 0x6B756D, dark: 0xB1BDB2)
    static let line = Color.dynamic(light: 0xE7E9E1, dark: 0x39453C)
    static let accent = Color.dynamic(light: 0x315E48, dark: 0xB8D7B3)
    static let tint = Color.dynamic(light: 0xEDF2E8, dark: 0x2F4032)
    static let hero = Color.dynamic(light: 0x315E48, dark: 0x365B44)
    static let firstSeries = Color.dynamic(light: 0x48765A, dark: 0xA2C99E)
    static let secondSeries = Color.dynamic(light: 0xA6743A, dark: 0xD4AC73)
    static func series(_ slot: Int) -> Color { slot == 0 ? firstSeries : secondSeries }
}

struct MortgagePanel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(padding)
            .background(MortgageStyle.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(MortgageStyle.line, lineWidth: 0.7) }
    }
}

struct MortgageOption: Identifiable {
    let id: String
    let title: String
}

struct MortgageSegment: View {
    let title: String
    let options: [MortgageOption]
    @Binding var selection: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 4) { choices }
            } else {
                HStack(spacing: 4) { choices }
            }
        }.padding(4).background(MortgageStyle.input, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    private var choices: some View {
        ForEach(options) { option in
            Button { selection = option.id } label: {
                Text(option.title).font(.subheadline.weight(selection == option.id ? .semibold : .regular))
                    .foregroundStyle(selection == option.id ? MortgageStyle.text : MortgageStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 3)
                    .background(selection == option.id ? MortgageStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                .accessibilityIdentifier("mortgage-option-" + option.id)
        }
    }
}

struct MortgageNumberField: View {
    let title: String
    @Binding var value: String
    var unit = ""
    var prominent = false
    var keyboard: UIKeyboardType = .decimalPad
    var identifier = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(MortgageStyle.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(title, text: $value).keyboardType(keyboard)
                    .font(prominent ? .system(.largeTitle, design: .rounded).weight(.semibold) : .body)
                    .monospacedDigit()
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(MortgageStyle.secondary) }
            }.padding(prominent ? 0 : 12).frame(minHeight: prominent ? 53 : 46)
                .background(prominent ? .clear : MortgageStyle.input, in: RoundedRectangle(cornerRadius: 13))
                .overlay(alignment: .bottom) { if prominent { Rectangle().fill(MortgageStyle.line).frame(height: 1) } }
        }
    }
}

struct MortgageFields: View {
    let fields: [FormField]
    @Binding var value: JSONValue
    private func text(_ key: String) -> Binding<String> { Binding(get: { value[key].text }, set: { value[key] = .string($0) }) }
    var body: some View {
        ForEach(fields) { field in
            switch field.kind {
            case .choice(let options):
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.title).font(.subheadline)
                    Picker(field.title, selection: text(field.id)) { ForEach(options) { Text($0.title).tag($0.id) } }
                        .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6).background(MortgageStyle.input, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(field.title).accessibilityIdentifier("mortgage-field-" + field.id)
                }
            case .toggle:
                Toggle(field.title, isOn: Binding(get: { value[field.id].flag }, set: { value[field.id] = .bool($0) }))
            default:
                MortgageNumberField(title: field.title, value: text(field.id), keyboard: keyboard(field.kind), identifier: "mortgage-field-" + field.id)
            }
        }
    }
    private func keyboard(_ kind: FormField.Kind) -> UIKeyboardType {
        switch kind { case .number: return .decimalPad; case .integer: return .numberPad; default: return .numbersAndPunctuation }
    }
}

struct MortgageTrialInputs: View {
    @Binding var draft: JSONValue
    let compare: () -> Void
    @State private var showRate = false
    private func text(_ key: String) -> Binding<String> { Binding(get: { draft[key].text }, set: { draft[key] = .string($0) }) }
    private var byPrice: Bool { draft["by"].text == "price" }
    private var rate: String {
        guard let lpr = draft["lpr"].numeric, let bp = draft["bp"].numeric else { return "—" }
        return MortgageDisplay.number(lpr + bp / 100) + "%"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            MortgageSegment(title: "贷款类型", options: [MortgageOption(id: "commercial", title: "商业贷款"), MortgageOption(id: "fund", title: "公积金贷"), MortgageOption(id: "combo", title: "组合贷款")], selection: text("type"))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(byPrice ? "按房价和首付" : "直接填贷款额").font(.caption).foregroundStyle(MortgageStyle.secondary)
                    Spacer()
                    Button { draft["by"] = .string(byPrice ? "amount" : "price") } label: {
                        Label(byPrice ? "填贷款额" : "填房价", systemImage: "arrow.left.arrow.right").font(.caption)
                    }.accessibilityIdentifier("mortgage-amount-mode")
                }
                MortgageNumberField(title: byPrice ? "房屋总价" : "贷款金额", value: text(byPrice ? "price" : "amount"), unit: "万元", prominent: true, identifier: "mortgage-amount")
            }
            if byPrice {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("首付比例").font(.subheadline)
                        Spacer()
                        Text("首付 \(MortgageDisplay.number(draft["price"].double * draft["down"].double / 100)) 万元").font(.caption).foregroundStyle(MortgageStyle.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { downPresets; downInput }
                        VStack(alignment: .leading, spacing: 10) { HStack(spacing: 8) { downPresets }; downInput }
                    }
                }
            }
            if draft["type"].text == "combo" {
                MortgageNumberField(title: "其中公积金贷款", value: text("fundAmount"), unit: "万元", identifier: "mortgage-fund-amount")
            }
            Divider().overlay(MortgageStyle.line)
            VStack(alignment: .leading, spacing: 10) {
                MortgageNumberField(title: "贷款年限", value: text("years"), unit: "年", identifier: "mortgage-years")
                Slider(value: Binding(get: { min(30, max(1, draft["years"].double)) }, set: { draft["years"] = .integer(Int($0)) }), in: 1...30, step: 1)
                    .accessibilityLabel("贷款年限滑块").accessibilityValue("\(draft["years"].text) 年")
                HStack { Text("1 年"); Spacer(); Text("共 \(MortgageDisplay.periods(draft["years"])) 期"); Spacer(); Text("30 年") }
                    .font(.caption).foregroundStyle(MortgageStyle.secondary)
            }
            if draft["type"].text != "fund" {
                DisclosureGroup(isExpanded: $showRate) {
                    VStack(spacing: 16) {
                        MortgageNumberField(title: "5 年期以上 LPR", value: text("lpr"), unit: "%", identifier: "mortgage-lpr")
                        MortgageNumberField(title: "加点（可负）", value: text("bp"), unit: "基点", keyboard: .numbersAndPunctuation, identifier: "mortgage-bp")
                        Text("1 基点 = 0.01%。按银行报价修改，年利率随之计算。")
                            .font(.caption).foregroundStyle(MortgageStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 14)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text("商贷年利率").font(.subheadline); Text("LPR + 加点").font(.caption).foregroundStyle(MortgageStyle.secondary) }
                        Spacer()
                        Text(rate).font(.title3.weight(.semibold)).foregroundStyle(MortgageStyle.text)
                    }
                }.accessibilityIdentifier("mortgage-rate-settings")
            }
            if draft["type"].text != "commercial" {
                MortgageNumberField(title: "公积金年利率", value: text("fundRate"), unit: "%", identifier: "mortgage-fund-rate")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("还款方式").font(.subheadline); Spacer(); Button("有什么区别", action: compare).font(.caption) }
                MortgageSegment(title: "还款方式", options: [MortgageOption(id: "equal", title: "等额本息"), MortgageOption(id: "principal", title: "等额本金")], selection: text("method"))
                Text(draft["method"].text == "principal" ? "本金每月相同，月供逐月减少，前期压力更大。" : "每月还款相同，适合稳定规划开支。")
                    .font(.caption).foregroundStyle(MortgageStyle.secondary)
            }
        }
    }
    private var downPresets: some View {
        ForEach([15, 20, 30], id: \.self) { percent in
            Button { draft["down"] = .integer(percent) } label: {
                Text("\(percent)%").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 8)
                    .background(draft["down"].double == Double(percent) ? MortgageStyle.tint : MortgageStyle.input, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).foregroundStyle(MortgageStyle.accent)
                .accessibilityAddTraits(draft["down"].double == Double(percent) ? .isSelected : [])
        }
    }
    private var downInput: some View {
        HStack(spacing: 3) {
            TextField("自定义", text: text("down")).keyboardType(.decimalPad).accessibilityLabel("自定义首付比例").accessibilityIdentifier("mortgage-down")
            Text("%").foregroundStyle(MortgageStyle.secondary)
        }.font(.subheadline).frame(minWidth: 55, maxWidth: 90, minHeight: 44).padding(.horizontal, 9)
            .background(MortgageStyle.input, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct MortgageSummaryCard: View {
    let presentation: MortgagePresentation
    let actionTitle: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 52
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack { paymentTitle; Spacer(); badge }
                    VStack(alignment: .leading, spacing: 8) { paymentTitle; badge }
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("¥").font(.title2.weight(.medium)).foregroundStyle(MortgageStyle.secondary).accessibilityHidden(true)
                    Text(MortgageDisplay.money(presentation.payment))
                        .font(.system(size: heroSize, weight: .semibold, design: .rounded)).tracking(-1.5)
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.45)
                        .accessibilityIdentifier("mortgage-monthly-payment")
                        .accessibilityLabel("人民币 " + MortgageDisplay.money(presentation.payment) + " 元")
                }
                Text(presentation.metadata.joined(separator: "  /  "))
                    .font(.caption).foregroundStyle(MortgageStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !presentation.isCurrent && !presentation.prepayment {
                MortgageCostBar(principal: presentation.calculation["total"].double, interest: presentation.result["interest"].double)
            }
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(presentation.metrics) { metric in
                            ViewThatFits(in: .horizontal) {
                                HStack { Text(metric.title); Spacer(); Text(metric.value + " " + metric.unit).fontWeight(.semibold) }
                                VStack(alignment: .leading, spacing: 5) { Text(metric.title); Text(metric.value + " " + metric.unit).fontWeight(.semibold) }
                            }.accessibilityElement(children: .combine)
                        }
                    }.font(.body)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(presentation.metrics.enumerated()), id: \.element.id) { index, metric in
                            if index > 0 { Rectangle().fill(MortgageStyle.line).frame(width: 1, height: 40).accessibilityHidden(true) }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(metric.title).font(.caption).foregroundStyle(MortgageStyle.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(metric.value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                                    Text(metric.unit).font(.caption2).foregroundStyle(MortgageStyle.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            Divider().overlay(MortgageStyle.line)
            Button(action: action) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(MortgageStyle.accent).padding(.top, 2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(presentation.insight).foregroundStyle(MortgageStyle.secondary)
                        Text(actionTitle).foregroundStyle(MortgageStyle.accent).fontWeight(.medium)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption2).padding(.top, 3)
                }.font(.caption).frame(minHeight: 44, alignment: .center)
            }.buttonStyle(.plain).accessibilityIdentifier("mortgage-result-action")
        }.padding(24).background(MortgageStyle.surface, in: RoundedRectangle(cornerRadius: 26))
            .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(MortgageStyle.line, lineWidth: 0.7) }
    }
    private var paymentTitle: some View { Text(presentation.paymentTitle).font(.subheadline).foregroundStyle(MortgageStyle.secondary) }
    private var badge: some View {
        Text(presentation.badge).font(.caption.weight(.medium)).foregroundStyle(MortgageStyle.accent)
            .padding(.horizontal, 10).padding(.vertical, 6).background(MortgageStyle.tint, in: Capsule())
    }
}

struct MortgageCostBar: View {
    let principal: Double
    let interest: Double
    private var fraction: Double {
        let total = principal + interest
        guard total.isFinite, total > 0 else { return 0 }
        return min(1, max(0, principal / total))
    }
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: fraction > 0 && fraction < 1 ? 3 : 0) {
                    if fraction > 0 { Capsule().fill(MortgageStyle.firstSeries).frame(width: max(0, geometry.size.width - (fraction < 1 ? 3 : 0)) * fraction) }
                    if fraction < 1 { Capsule().fill(MortgageStyle.secondSeries.opacity(0.65)) }
                }
            }.frame(height: 6).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack { principalLabel; Spacer(); interestLabel }
                VStack(alignment: .leading, spacing: 6) { principalLabel; interestLabel }
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("本金占累计还款的 \(MortgageDisplay.number(fraction * 100, decimals: 1))%，其余为利息")
    }
    private var principalLabel: some View {
        Text("本金 \(MortgageDisplay.number(fraction * 100, decimals: 1))%")
            .font(.caption2).foregroundStyle(MortgageStyle.secondary)
    }
    private var interestLabel: some View {
        Text("利息 \(MortgageDisplay.number((1 - fraction) * 100, decimals: 1))%")
            .font(.caption2).foregroundStyle(MortgageStyle.secondary)
    }
}

struct MortgageQuickFact: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(MortgageStyle.secondary)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

struct MortgageStrategyOption: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(MortgageStyle.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(MortgageStyle.secondary) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(14)
                .background(selected ? MortgageStyle.tint : MortgageStyle.input, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? MortgageStyle.accent.opacity(0.5) : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
