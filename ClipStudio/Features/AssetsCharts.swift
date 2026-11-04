import SwiftUI
import Charts

struct AssetsChartPoint: Identifiable, Equatable {
    let date: Date
    let label: String
    let value: Double
    let series: String
    var id: String { series + "-" + label }
}

enum AssetsChartData {
    static func points(_ rows: [JSONValue], fields: [(String, String)], dateKey: String = "on") -> [AssetsChartPoint] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return fields.flatMap { key, series in
            rows.compactMap { row -> AssetsChartPoint? in
                let label = row[dateKey].text
                let fullDate = label.count == 7 ? label + "-01" : label
                guard let date = formatter.date(from: fullDate), formatter.string(from: date) == fullDate,
                      let value = row[key].numeric else { return nil }
                return AssetsChartPoint(date: date, label: label, value: value, series: series)
            }
        }.sorted { $0.date < $1.date }
    }
}

struct AssetsTrend: View {
    let title: String
    let points: [AssetsChartPoint]
    let series: [String]
    var unit = "元/天"
    var palette: Palette = .comparison
    enum Palette { case itemCost, comparison }
    @Environment(\.assetsPrivacy) private var privacy
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedDate: Date?

    private var colors: [Color] {
        if palette == .itemCost { return [Color.dynamic(light: 0x287F4F, dark: 0x3F9E69)] }
        let slots = [Color.dynamic(light: 0x2A78D6, dark: 0x3987E5),
                     Color.dynamic(light: 0xEB6834, dark: 0xD95926),
                     Color.dynamic(light: 0x1BAF7A, dark: 0x199E70)]
        return series.map { name in
            let index = slot(name)
            return slots.indices.contains(index) ? slots[index] : Theme.text2
        }
    }
    private func color(_ name: String) -> Color {
        guard let index = series.firstIndex(of: name), colors.indices.contains(index) else { return Theme.text2 }
        return colors[index]
    }
    private func slot(_ name: String) -> Int { name == "目标日耗" ? 2 : series.firstIndex(of: name) ?? 0 }
    private func dash(_ name: String) -> [CGFloat] {
        switch slot(name) {
        case 1: return [6, 4]
        case 2: return [2, 4]
        default: return []
        }
    }
    private var lastPoints: [AssetsChartPoint] {
        series.compactMap { name in points.last(where: { $0.series == name }) }
    }
    private var selected: [AssetsChartPoint] {
        guard let selectedDate, let closest = points.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) else { return [] }
        return points.filter { $0.date == closest.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(unit).font(.caption).foregroundStyle(Theme.text2)
            }
            if privacy.wrappedValue {
                Label("金额已隐藏", systemImage: "eye.slash").font(.callout).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, minHeight: 140)
            } else if points.isEmpty {
                Text("暂无可绘制的数据").font(.callout).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                plot
                if let first = selected.first { Text(first.label).font(.caption.weight(.medium)) }
                ForEach(selected.isEmpty ? lastPoints : selected) { point in
                    LabeledContent(point.series, value: "¥" + Display.money(.number(point.value)))
                        .font(.caption).foregroundStyle(Theme.text).monospacedDigit()
                }
                DisclosureGroup("查看数据") {
                    VStack(spacing: 12) {
                        ForEach(points) { point in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading) { Text(point.label); Text(point.series).foregroundStyle(Theme.text2) }
                                Spacer()
                                Text("¥" + Display.money(.number(point.value))).monospacedDigit()
                            }.font(.caption)
                        }
                    }.padding(.top, 12)
                }.font(.caption).tint(Theme.accent).accessibilityIdentifier("assets-chart-data")
            }
        }.foregroundStyle(Theme.text)
    }

    private var plot: some View {
        Chart {
            if palette == .itemCost {
                ForEach(points) { point in
                    AreaMark(x: .value("日期", point.date), y: .value("数值", point.value))
                        .foregroundStyle(colors[0].opacity(0.10))
                }
            }
            ForEach(points) { point in
                LineMark(x: .value("日期", point.date), y: .value("数值", point.value))
                    .foregroundStyle(by: .value("系列", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: dash(point.series)))
                    .accessibilityLabel(point.label + "，" + point.series)
                    .accessibilityValue(Display.money(.number(point.value)) + " " + unit)
            }
            ForEach(lastPoints) { point in
                PointMark(x: .value("日期", point.date), y: .value("数值", point.value))
                    .symbol {
                        Circle().fill(color(point.series)).overlay { Circle().stroke(Theme.background, lineWidth: 2) }.frame(width: 8, height: 8)
                    }
                    .accessibilityHidden(true)
            }
            if let first = selected.first {
                RuleMark(x: .value("所选日期", first.date)).foregroundStyle(Theme.text2.opacity(0.4))
            }
        }.frame(height: typeSize.isAccessibilitySize ? 280 : 180)
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .chartForegroundStyleScale(domain: series, range: Array(colors.prefix(series.count)))
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartLegend(series.count > 1 ? .visible : .hidden)
            .chartXSelection(value: $selectedDate)
    }
}
