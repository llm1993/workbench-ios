import SwiftUI
import Charts

struct MortgageBalanceChart: View {
    let series: [MortgageBalanceSeries]
    let months: Int
    let title: String
    let subtitle: String
    let schedule: () -> Void
    let showData: () -> Void
    @State private var selectedMonth: Int?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var ticks: [Int] { Array(Set([0, max(1, months / 2), months])).sorted() }
    var body: some View {
        MortgagePanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { heading; Spacer(); scheduleButton }
                VStack(alignment: .leading, spacing: 10) { heading; scheduleButton }
            }
            if series.count > 1 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { legend }
                    VStack(alignment: .leading, spacing: 10) { legend }
                }
            }
            plot
            VStack(alignment: .leading, spacing: 6) {
                if let month = selectedMonth {
                    Text(month == 0 ? "还款起点" : "第 \(month) 期 · \(MortgageDisplay.number(Double(month) / 12, decimals: 1)) 年")
                        .font(.caption.weight(.medium))
                    ForEach(series) { item in
                        if let value = item.balance(at: month) {
                            LabeledContent(item.title, value: MortgageDisplay.wan(.number(value)) + " 万元").font(.caption).monospacedDigit()
                        }
                    }
                } else { Text("按住曲线，查看每期剩余本金").font(.caption).foregroundStyle(MortgageStyle.secondary) }
            }.frame(maxWidth: .infinity, minHeight: selectedMonth == nil ? 24 : 56, alignment: .topLeading)
                .accessibilityIdentifier("mortgage-chart-readout")
            Divider().overlay(MortgageStyle.line)
            HStack {
                Text("单位：万元").font(.caption).foregroundStyle(MortgageStyle.secondary)
                Spacer()
                Button("查看数据", action: showData).font(.caption.weight(.medium)).frame(minHeight: 44)
                    .accessibilityIdentifier("mortgage-chart-data")
            }
        }.onChange(of: series) { _, _ in selectedMonth = nil }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(MortgageStyle.secondary)
        }
    }
    private var scheduleButton: some View {
        Button(action: schedule) {
            Label("还款明细", systemImage: "chevron.right").font(.caption.weight(.medium))
                .padding(.horizontal, 11).frame(minHeight: 44).background(MortgageStyle.tint, in: Capsule())
        }.buttonStyle(.plain)
            .accessibilityIdentifier("mortgage-schedule")
    }
    private var legend: some View {
        ForEach(series) { item in
            HStack(spacing: 6) {
                Path { path in path.move(to: CGPoint(x: 0, y: 4)); path.addLine(to: CGPoint(x: 19, y: 4)) }
                    .stroke(MortgageStyle.series(item.slot), style: StrokeStyle(lineWidth: 2, dash: item.slot == 0 ? [] : [5, 3]))
                    .frame(width: 19, height: 8).accessibilityHidden(true)
                Text(item.title).font(.caption).foregroundStyle(MortgageStyle.secondary)
            }
        }
    }
    private var plot: some View {
        Chart {
            ForEach(series) { item in
                ForEach(item.points) { point in
                    if item.slot == 0 {
                        AreaMark(x: .value("期数", point.month), y: .value("剩余本金（万元）", point.balance / 10_000))
                            .foregroundStyle(MortgageStyle.firstSeries.opacity(0.07)).accessibilityHidden(true)
                    }
                    LineMark(x: .value("期数", point.month), y: .value("剩余本金（万元）", point.balance / 10_000))
                        .foregroundStyle(by: .value("还款计划", item.title))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: item.slot == 0 ? [] : [5, 4]))
                        .accessibilityLabel("\(item.title)，第 \(point.month) 期")
                        .accessibilityValue(MortgageDisplay.wan(.number(point.balance)) + " 万元")
                }
            }
            if let month = selectedMonth {
                RuleMark(x: .value("所选期数", month)).foregroundStyle(MortgageStyle.secondary.opacity(0.4))
                ForEach(series) { item in
                    if let value = item.balance(at: month) {
                        PointMark(x: .value("期数", month), y: .value("剩余本金（万元）", value / 10_000))
                            .symbol {
                                Circle().fill(MortgageStyle.series(item.slot))
                                    .overlay { Circle().strokeBorder(MortgageStyle.surface, lineWidth: 2) }.frame(width: 10, height: 10)
                            }.accessibilityHidden(true)
                    }
                }
            }
        }.frame(height: typeSize.isAccessibilitySize ? 270 : 180)
            .chartForegroundStyleScale(domain: series.map(\.title), range: series.map { MortgageStyle.series($0.slot) })
            .chartLegend(.hidden).chartXScale(domain: 0...max(1, months))
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis {
                AxisMarks(values: ticks) { value in
                    AxisValueLabel {
                        if let month = value.as(Int.self) {
                            Text(month == 0 ? "现在" : MortgageDisplay.number(Double(month) / 12, decimals: 1) + " 年")
                                .font(.caption2).foregroundStyle(MortgageStyle.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7)).foregroundStyle(MortgageStyle.line)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(MortgageDisplay.number(amount, decimals: 1)).font(.caption2).foregroundStyle(MortgageStyle.secondary) }
                    }
                }
            }
            .chartXSelection(value: $selectedMonth)
            .accessibilityLabel(title).accessibilityHint("可调整以查看每年数据，或使用下方查看数据按钮。")
            .accessibilityAdjustableAction { direction in
                let change = direction == .increment ? 12 : -12
                selectedMonth = min(months, max(0, (selectedMonth ?? 0) + change))
            }
    }
}
