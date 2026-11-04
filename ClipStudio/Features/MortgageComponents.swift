import SwiftUI

enum MortgageStyle {
    static let background = Color.dynamic(light: 0xF3F6F5, dark: 0x151F1A)
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1D2A23)
    static let input = Color.dynamic(light: 0xF7F9F8, dark: 0x25352D)
    static let text = Color.dynamic(light: 0x203D33, dark: 0xE5EEE8)
    static let secondary = Color.dynamic(light: 0x63736C, dark: 0xB0C2B7)
    static let line = Color.dynamic(light: 0xE2E9E5, dark: 0x35483C)
    static let accent = Color.dynamic(light: 0x245C4D, dark: 0x9DC9B5)
    static let tint = Color.dynamic(light: 0xE8F0EC, dark: 0x2C4235)
    static let hero = Color.dynamic(light: 0x245C4D, dark: 0x264D40)
    static let firstSeries = Color.dynamic(light: 0x237E5B, dark: 0x299A70)
    static let secondSeries = Color.dynamic(light: 0x9670C5, dark: 0x9670C5)
    static func series(_ slot: Int) -> Color { slot == 0 ? firstSeries : secondSeries }
}

struct MortgagePanel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(padding)
            .background(MortgageStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(MortgageStyle.line, lineWidth: 0.7) }
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
        }.padding(4).background(MortgageStyle.input, in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    private var choices: some View {
        ForEach(options) { option in
            Button { selection = option.id } label: {
                Text(option.title).font(.subheadline.weight(selection == option.id ? .semibold : .regular))
                    .foregroundStyle(selection == option.id ? MortgageStyle.accent : MortgageStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40).padding(.horizontal, 3)
                    .background(selection == option.id ? MortgageStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
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
            Text(title).font(.subheadline).foregroundStyle(MortgageStyle.text)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(title, text: $value).keyboardType(keyboard)
                    .font(prominent ? .system(.largeTitle, design: .default).weight(.medium) : .body)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(MortgageStyle.secondary) }
            }.padding(prominent ? 0 : 12).frame(minHeight: prominent ? 53 : 46)
                .background(prominent ? .clear : MortgageStyle.input, in: RoundedRectangle(cornerRadius: 10))
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
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 54
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack { paymentTitle; Spacer(); badge }
                    VStack(alignment: .leading, spacing: 8) { paymentTitle; badge }
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("¥").font(.title2).foregroundStyle(.white.opacity(0.78))
                    Text(MortgageDisplay.money(presentation.payment))
                        .font(.system(size: heroSize, weight: .semibold)).tracking(-1.5)
                        .lineLimit(1).minimumScaleFactor(0.45)
                        .accessibilityIdentifier("mortgage-monthly-payment")
                }.accessibilityElement(children: .combine)
                Text(presentation.metadata.joined(separator: "  /  "))
                    .font(.caption).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24).foregroundStyle(.white)
                .background(MortgageStyle.hero)
                .overlay(alignment: .bottomTrailing) { Image(systemName: "house").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.white.opacity(0.1)).padding(22).accessibilityHidden(true).allowsHitTesting(false) }
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 16) { ForEach(presentation.metrics) { metric in HStack { Text(metric.title); Spacer(); Text(metric.value + " " + metric.unit).fontWeight(.semibold) } } }.font(.body)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(presentation.metrics.enumerated()), id: \.element.id) { index, metric in
                            if index > 0 { Rectangle().fill(MortgageStyle.line).frame(width: 1, height: 45) }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(metric.title).font(.caption).foregroundStyle(MortgageStyle.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(metric.value).font(.system(.title3, design: .default).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
                                    Text(metric.unit).font(.caption2).foregroundStyle(MortgageStyle.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                        }
                    }
                }
            }.padding(20)
            Rectangle().fill(MortgageStyle.line).frame(height: 0.7)
            Button(action: action) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").padding(.top, 2)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(presentation.insight).foregroundStyle(MortgageStyle.secondary)
                        Text(actionTitle).foregroundStyle(MortgageStyle.accent).fontWeight(.medium)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption2).padding(.top, 3)
                }.font(.caption).frame(minHeight: 44, alignment: .center).padding(.horizontal, 20).padding(.vertical, 10)
            }.buttonStyle(.plain).accessibilityIdentifier("mortgage-result-action")
        }.background(MortgageStyle.surface).clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(MortgageStyle.line, lineWidth: 0.7) }
    }
    private var paymentTitle: some View { Text(presentation.paymentTitle).font(.subheadline).foregroundStyle(.white.opacity(0.9)) }
    private var badge: some View {
        Text(presentation.badge).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.35), lineWidth: 0.7) }
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
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.title3).foregroundStyle(MortgageStyle.accent)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(MortgageStyle.secondary) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(14)
                .background(selected ? MortgageStyle.tint : MortgageStyle.input, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? MortgageStyle.accent.opacity(0.5) : MortgageStyle.line, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
