import SwiftUI

enum SalaryStyle {
    static let background = Color.dynamic(light: 0xF2F1EA, dark: 0x101615)
    static let surface = Color.dynamic(light: 0xFFFDF9, dark: 0x18211F)
    static let input = Color.dynamic(light: 0xF3F2EA, dark: 0x212C29)
    static let text = Color.dynamic(light: 0x1C2B28, dark: 0xE9F0ED)
    static let secondary = Color.dynamic(light: 0x6B7873, dark: 0xA3B1AC)
    static let line = Color.dynamic(light: 0xE4E5DC, dark: 0x2C3A36)
    static let line2 = Color.dynamic(light: 0xD3D6CA, dark: 0x3B4C47)
    static let accent = Color.dynamic(light: 0x10635A, dark: 0x7FD3C2)
    static let tint = Color.dynamic(light: 0xE3EEEA, dark: 0x1E332F)
    static let onAccent = Color.dynamic(light: 0xFFFFFF, dark: 0x0D1A18)
    static let net = Color.dynamic(light: 0x0E7C66, dark: 0x4FCBA8)
    static let tax = Color.dynamic(light: 0xC4453C, dark: 0xF08A80)
    static let social = Color.dynamic(light: 0x2F6BD0, dark: 0x7FB0F5)
    static let fund = Color.dynamic(light: 0xC8891B, dark: 0xE9B75C)
    static let other = Color.dynamic(light: 0x6D5AA8, dark: 0xB3A2E8)

    static func color(_ kind: SalaryFlowKind) -> Color {
        switch kind {
        case .gross: return secondary
        case .social: return social
        case .fund: return fund
        case .tax: return tax
        case .other: return other
        case .net: return net
        }
    }
    static func soft(_ kind: SalaryFlowKind) -> Color { color(kind).opacity(0.14) }
}

struct SalaryPanel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(padding)
            .background(SalaryStyle.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(SalaryStyle.line, lineWidth: 0.7) }
    }
}

struct SalaryPanelHeading: View {
    let title: String
    var subtitle: String?
    var pill: String?
    var pillKind: SalaryFlowKind?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { heading; Spacer(minLength: 8); if let pill { badge(pill) } }
                VStack(alignment: .leading, spacing: 8) { heading; if let pill { badge(pill) } }
            }
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(SalaryStyle.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private var heading: some View { Text(title).font(.headline).fixedSize(horizontal: false, vertical: true) }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).monospacedDigit()
            .foregroundStyle(pillKind.map(SalaryStyle.color) ?? SalaryStyle.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((pillKind.map(SalaryStyle.soft) ?? SalaryStyle.tint), in: Capsule())
            .fixedSize()
    }
}

struct SalaryOption: Identifiable {
    let id: String
    let title: String
}

struct SalarySegment: View {
    let title: String
    let options: [SalaryOption]
    @Binding var selection: String
    var identifier = "salary-segment"
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize { VStack(spacing: 4) { choices } }
            else { HStack(spacing: 4) { choices } }
        }.padding(4).background(SalaryStyle.input, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    private var choices: some View {
        ForEach(options) { option in
            Button { selection = option.id } label: {
                Text(option.title).font(.subheadline.weight(selection == option.id ? .semibold : .regular))
                    .foregroundStyle(selection == option.id ? SalaryStyle.text : SalaryStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 3)
                    .background(selection == option.id ? SalaryStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                .accessibilityIdentifier(identifier + "-" + option.id)
        }
    }
}

struct SalaryNumberField: View {
    let title: String
    @Binding var value: String
    var unit = ""
    var prominent = false
    var keyboard: UIKeyboardType = .decimalPad
    var identifier = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(SalaryStyle.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(title, text: $value).keyboardType(keyboard)
                    .font(prominent ? .system(.title2, design: .rounded).weight(.semibold) : .body)
                    .monospacedDigit().textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(SalaryStyle.secondary) }
            }.padding(prominent ? 0 : 12).frame(minHeight: prominent ? 48 : 46)
                .background(prominent ? .clear : SalaryStyle.input, in: RoundedRectangle(cornerRadius: 13))
                .overlay(alignment: .bottom) { if prominent { Rectangle().fill(SalaryStyle.line).frame(height: 1) } }
        }
    }
}

struct SalarySlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var readout: String
    var identifier = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline)
                Spacer(minLength: 8)
                Text(readout).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(SalaryStyle.accent)
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title).accessibilityValue(readout).accessibilityIdentifier(identifier)
        }
    }
}

struct SalaryStepper: View {
    let title: String
    let value: Int
    var limit = 6
    let change: (Int) -> Void
    var identifier = ""
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                button("−", delta: -1, disabled: value <= 0)
                Text("\(value)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 34, minHeight: 40)
                button("+", delta: 1, disabled: value >= limit)
            }.background(SalaryStyle.input, in: RoundedRectangle(cornerRadius: 12))
        }.accessibilityElement(children: .contain).accessibilityLabel(title)
            .accessibilityValue("\(value)")
    }
    private func button(_ label: String, delta: Int, disabled: Bool) -> some View {
        Button { change(delta) } label: {
            Text(label).font(.title3.weight(.medium)).frame(width: 40, height: 40)
                .foregroundStyle(disabled ? SalaryStyle.secondary.opacity(0.4) : SalaryStyle.accent)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled)
            .accessibilityLabel(label == "−" ? "减少\(title)" : "增加\(title)")
            .accessibilityIdentifier(identifier + (delta < 0 ? "-minus" : "-plus"))
    }
}

struct SalaryToggleChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var identifier = ""
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? SalaryStyle.accent : SalaryStyle.secondary)
                .padding(.horizontal, 14).frame(minHeight: 40)
                .background(selected ? SalaryStyle.tint : SalaryStyle.input, in: Capsule())
                .overlay { Capsule().strokeBorder(selected ? SalaryStyle.accent.opacity(0.45) : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(identifier)
    }
}

struct SalaryNotice: View {
    let messages: [String]
    var body: some View {
        if !messages.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.subheadline).foregroundStyle(SalaryStyle.fund).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(messages, id: \.self) { Text($0).font(.caption).foregroundStyle(SalaryStyle.text).fixedSize(horizontal: false, vertical: true) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(SalaryStyle.fund.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("salary-notice")
        }
    }
}

struct SalaryFlowBar: View {
    let shares: [SalaryShare]
    var summary: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(shares) { share in
                        Capsule().fill(SalaryStyle.color(share.kind))
                            .frame(width: max(2, (geometry.size.width - CGFloat(shares.count - 1) * 2) * share.ratio))
                    }
                }
            }.frame(height: 7).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { labels }
                VStack(alignment: .leading, spacing: 6) { labels }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(summary)
    }
    private var labels: some View {
        ForEach(shares) { share in
            HStack(spacing: 5) {
                Circle().fill(SalaryStyle.color(share.kind)).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("\(share.title) \(SalaryDisplay.percent(share.ratio))").font(.caption2).monospacedDigit()
                    .foregroundStyle(SalaryStyle.secondary)
            }
        }
    }
}

struct SalaryMetricRow: View {
    let metrics: [SalaryMetric]
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(metrics) { metric in
                    HStack { Text(metric.title); Spacer(); Text(metric.value + " " + metric.unit).fontWeight(.semibold) }
                        .accessibilityElement(children: .combine)
                }
            }.font(.subheadline)
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 { Rectangle().fill(SalaryStyle.line).frame(width: 1, height: 38).accessibilityHidden(true) }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(metric.title).font(.caption).foregroundStyle(SalaryStyle.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(metric.value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text(metric.unit).font(.caption2).foregroundStyle(SalaryStyle.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct SalaryReceiptLine: View {
    let line: SalaryLine
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if line.kind != .gross || line.emphasis {
                Circle().fill(SalaryStyle.color(line.kind)).frame(width: 7, height: 7)
                    .accessibilityHidden(true).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).font(line.emphasis ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(line.muted ? SalaryStyle.secondary : SalaryStyle.text)
                if !line.note.isEmpty {
                    Text(line.note).font(.caption2).foregroundStyle(SalaryStyle.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(SalaryDisplay.signed(line.amount))
                .font(.system(.subheadline, design: .rounded).weight(line.emphasis ? .semibold : .regular))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(amountColor)
        }.frame(minHeight: 30).accessibilityElement(children: .combine)
    }
    private var amountColor: Color {
        if line.emphasis { return line.kind == .net ? SalaryStyle.net : (line.amount < 0 ? SalaryStyle.tax : SalaryStyle.text) }
        if line.muted { return SalaryStyle.secondary }
        return line.amount < 0 ? SalaryStyle.color(line.kind) : SalaryStyle.text
    }
}

struct SalaryBarList: View {
    let bars: [SalaryBar]
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(bars) { bar in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bar.title).font(.caption).foregroundStyle(SalaryStyle.secondary)
                        Spacer(minLength: 8)
                        Text(bar.value).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(SalaryStyle.text)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(SalaryStyle.input)
                            Capsule().fill(SalaryStyle.color(bar.kind))
                                .frame(width: max(2, geometry.size.width * min(1, max(0, bar.ratio))))
                        }
                    }.frame(height: 7).accessibilityHidden(true)
                }.accessibilityElement(children: .combine)
            }
        }
    }
}

private struct SalaryDash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

/// The payslip tear line: a perforation with punch-hole notches at both card edges.
struct SalaryTearLine: View {
    var body: some View {
        ZStack {
            SalaryDash().stroke(SalaryStyle.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 4])).frame(height: 1)
            HStack(spacing: 0) {
                Circle().fill(SalaryStyle.background).frame(width: 14, height: 14).offset(x: -7)
                Spacer(minLength: 0)
                Circle().fill(SalaryStyle.background).frame(width: 14, height: 14).offset(x: 7)
            }
        }.frame(height: 14).padding(.horizontal, -20).accessibilityHidden(true)
    }
}

struct SalaryMonthStrip: View {
    let rows: [JSONValue]
    let selection: Int
    let select: (Int) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        let month = row["month"].int
                        Button { select(month) } label: {
                            VStack(spacing: 3) {
                                Text("\(month) 月").font(.caption.weight(selection == month ? .semibold : .regular))
                                Text(row["active"].flag ? SalaryDisplay.compact(row["net"].double) : "—")
                                    .font(.caption2.weight(.medium)).monospacedDigit()
                            }.frame(minWidth: 58, minHeight: 52)
                                .foregroundStyle(selection == month ? SalaryStyle.onAccent : SalaryStyle.text)
                                .background(selection == month ? SalaryStyle.accent : SalaryStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14).strokeBorder(
                                        row["bonus"].double > 0 ? SalaryStyle.fund : SalaryStyle.line,
                                        lineWidth: row["bonus"].double > 0 ? 1.2 : 0.7)
                                }
                        }.buttonStyle(.plain).id(month)
                            .accessibilityLabel("\(month) 月")
                            .accessibilityValue(row["active"].flag ? "到手 \(SalaryDisplay.money(row["net"].double)) 元" : "未入职")
                            .accessibilityAddTraits(selection == month ? .isSelected : [])
                            .accessibilityIdentifier("salary-month-\(month)")
                    }
                }.padding(.horizontal, 2).padding(.vertical, 2)
            }.onChange(of: selection) { _, value in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(value, anchor: .center) }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("月份选择")
            .accessibilityIdentifier("salary-month-strip")
    }
}
struct SalaryMenu: View {
    let title: String
    let value: String
    let options: [SalaryOption]
    let select: (String) -> Void
    var identifier = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(SalaryStyle.secondary)
            Menu {
                ForEach(options) { option in
                    Button { select(option.id) } label: {
                        if option.id == value { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }.accessibilityIdentifier(identifier + "-" + option.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(options.first { $0.id == value }?.title ?? value).font(.body).foregroundStyle(SalaryStyle.text)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(SalaryStyle.secondary)
                        .accessibilityHidden(true)
                }.padding(.horizontal, 12).frame(minHeight: 46)
                    .background(SalaryStyle.input, in: RoundedRectangle(cornerRadius: 13))
            }.menuIndicator(.hidden).accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}

struct SalarySubheading: View {
    let title: String
    var readout: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            if let readout {
                Text(readout).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(SalaryStyle.accent)
            }
        }
    }
}

struct SalaryActionChip: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var identifier = ""
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 40).foregroundStyle(SalaryStyle.accent)
                .background(SalaryStyle.input, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(identifier)
    }
}

struct SalaryPrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var filled = true
    var identifier = ""
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(filled ? SalaryStyle.onAccent : SalaryStyle.accent)
                .background(filled ? SalaryStyle.accent : SalaryStyle.tint, in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}
