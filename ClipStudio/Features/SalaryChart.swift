import SwiftUI

private struct SalaryChartSegment: Identifiable {
    let kind: SalaryFlowKind
    let value: Double
    var id: String { kind.rawValue }
}

/// Stacked monthly bars drawn by hand so the jump markers, inactive stubs and
/// bonus-month caption land exactly where the approved design puts them.
struct SalaryFlowChart: View {
    let bars: [SalaryChartBar]
    let unit: Double
    let selection: Int
    let bonusMonth: Int?
    let select: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var plotHeight: CGFloat { typeSize.isAccessibilitySize ? 250 : 176 }
    private var top: Double {
        let peak = max(1, bars.map(\.total).max() ?? 1)
        return (peak / unit).rounded(.up) * unit
    }
    var body: some View {
        let area = plotHeight - 14
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                let y = 14 + area * CGFloat(index) / 2
                Rectangle().fill(SalaryStyle.line).frame(height: index == 2 ? 0.9 : 0.6)
                    .padding(.leading, 30).offset(y: y)
                Text(SalaryDisplay.number(top * Double(2 - index) / 2 / unit, decimals: 1))
                    .font(.caption2).monospacedDigit().foregroundStyle(SalaryStyle.secondary)
                    .frame(width: 26, alignment: .trailing).offset(y: y - 7)
            }
            HStack(spacing: 0) { ForEach(bars) { column($0, area: area) } }.padding(.leading, 30)
        }.frame(maxWidth: .infinity, minHeight: plotHeight + 30, alignment: .topLeading)
            .accessibilityElement(children: .contain).accessibilityLabel("十二个月到手工资与扣除构成")
    }
    private func column(_ bar: SalaryChartBar, area: CGFloat) -> some View {
        let height = max(0, CGFloat(bar.total / top) * area)
        return Button { select(bar.month) } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    if bar.month == selection {
                        RoundedRectangle(cornerRadius: 7).fill(SalaryStyle.tint).frame(height: plotHeight)
                    }
                    VStack(spacing: 0) {
                        if let jump = bar.jumpTo {
                            Text("↑\(Int((jump * 100).rounded()))%").font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(SalaryStyle.tax).frame(height: 14)
                        } else { Color.clear.frame(height: 14) }
                        Spacer(minLength: 0)
                        if bar.active {
                            VStack(spacing: 0) { segments(bar, area: area) }
                                .frame(width: 15, height: height).clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(SalaryStyle.line2).frame(width: 15, height: 5)
                        }
                    }.frame(height: plotHeight)
                }.frame(height: plotHeight)
                Text("\(bar.month)").font(.caption2.weight(bar.month == selection ? .bold : .regular))
                    .foregroundStyle(bar.month == selection ? SalaryStyle.accent : SalaryStyle.secondary).frame(height: 18)
                Text(bonusMonth == bar.month ? "年终奖" : " ").font(.system(size: 8))
                    .foregroundStyle(SalaryStyle.fund).frame(height: 12)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(bar.month) 月")
            .accessibilityValue(bar.active ? "到手 \(SalaryDisplay.money(bar.net)) 元" : "未入职")
            .accessibilityAddTraits(bar.month == selection ? .isSelected : [])
            .accessibilityIdentifier("salary-chart-\(bar.month)")
    }
    private func segments(_ bar: SalaryChartBar, area: CGFloat) -> some View {
        let parts = [SalaryChartSegment(kind: .other, value: bar.other), SalaryChartSegment(kind: .tax, value: bar.tax),
                     SalaryChartSegment(kind: .social, value: bar.social), SalaryChartSegment(kind: .fund, value: bar.fund),
                     SalaryChartSegment(kind: .net, value: bar.net)].filter { $0.value > 0 }
        return ForEach(parts) { part in
            Rectangle().fill(SalaryStyle.color(part.kind)).frame(height: max(0.6, CGFloat(part.value / top) * area))
        }
    }
}

struct SalaryChartPanel: View {
    let presentation: SalaryPresentation
    @Binding var withBonus: Bool
    let select: (Int) -> Void
    let detail: () -> Void
    let explain: () -> Void
    private var legend: [SalaryFlowKind] {
        var kinds: [SalaryFlowKind] = [.net, .fund, .social, .tax]
        if presentation.main["afterTax"].double > 0 { kinds.append(.other) }
        return kinds
    }
    var body: some View {
        SalaryPanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { heading; Spacer(minLength: 8); detailButton }
                VStack(alignment: .leading, spacing: 10) { heading; detailButton }
            }
            SalarySegment(title: "图表口径",
                          options: [SalaryOption(id: "salary", title: "只看月薪"), SalaryOption(id: "all", title: "含年终奖")],
                          selection: Binding(get: { withBonus ? "all" : "salary" }, set: { withBonus = $0 == "all" }),
                          identifier: "salary-chart-mode")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { legendLabels }
                VStack(alignment: .leading, spacing: 6) { legendLabels }
            }
            SalaryFlowChart(bars: presentation.chartBars, unit: presentation.chartUnit,
                            selection: presentation.month, bonusMonth: withBonus ? presentation.bonusMonth : nil,
                            select: select)
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.chartReadTitle).font(.caption).foregroundStyle(SalaryStyle.secondary)
                Spacer(minLength: 8)
                Text("¥" + SalaryDisplay.money(presentation.chartReadValue))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(SalaryStyle.net)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("salary-chart-readout")
            Divider().overlay(SalaryStyle.line)
            HStack {
                Text("点柱子切换月份 · 单位：\(presentation.chartUnitTitle)").font(.caption2).foregroundStyle(SalaryStyle.secondary)
                Spacer(minLength: 8)
                Button("怎么算的", action: explain).font(.caption.weight(.medium)).frame(minHeight: 44)
                    .accessibilityIdentifier("salary-explain")
            }
        }.accessibilityIdentifier("salary-chart")
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("逐月到手").font(.headline)
            Text(presentation.chartSubtitle).font(.caption).foregroundStyle(SalaryStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var detailButton: some View {
        Button(action: detail) {
            Label("全年明细", systemImage: "chevron.right").font(.caption.weight(.medium))
                .padding(.horizontal, 11).frame(minHeight: 44).background(SalaryStyle.tint, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("salary-year-detail")
    }
    @ViewBuilder private var legendLabels: some View {
        ForEach(legend) { kind in
            HStack(spacing: 5) {
                Circle().fill(SalaryStyle.color(kind)).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(kind == .other ? "税后扣款" : kind.title).font(.caption2).foregroundStyle(SalaryStyle.secondary)
            }
        }
        Text("↑ 表示当月税率跳档").font(.caption2).foregroundStyle(SalaryStyle.tax)
    }
}