import SwiftUI

struct SalaryCompareScene: View {
    let presentation: SalaryPresentation
    @Binding var offerA: JSONValue
    @Binding var offerB: JSONValue
    let offerAResult: JSONValue
    let offerBResult: JSONValue
    let marginal: JSONValue
    let trap: JSONValue
    @Binding var raiseDelta: Double
    let cities: [JSONValue]
    let syncOffer: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var cityOptions: [SalaryOption] { cities.map { SalaryOption(id: $0["key"].text, title: $0["name"].text) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            bonusPanel
            offerPanel
            raisePanel
            yearPanel
        }
    }

    private var bonusPanel: some View {
        SalaryPanel {
            SalaryPanelHeading(title: "年终奖两种算法",
                               subtitle: "同一笔年终奖，选错方式一年可能差几千元。",
                               pill: presentation.hasBonus ? "年终奖 ¥" + SalaryDisplay.whole(presentation.main["bonus"].double) : "未填年终奖",
                               pillKind: presentation.hasBonus ? .fund : nil)
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) { bonusCards }
            } else {
                HStack(alignment: .top, spacing: 12) { bonusCards }
            }
            deltaBox(presentation.bonusDelta, symbol: presentation.hasBonus ? "arrow.up" : "exclamationmark.triangle",
                     flat: !presentation.hasBonus, identifier: "salary-bonus-delta")
            Text(SalaryPresentation.trapText(trap, bonus: presentation.main["bonus"].double))
                .font(.caption2).foregroundStyle(SalaryStyle.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("salary-bonus-trap")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("salary-bonus-compare")
    }
    private var bonusCards: some View {
        ForEach(presentation.bonusCards) { card in
            VStack(alignment: .leading, spacing: 8) {
                if card.best {
                    Text("更省税").font(.caption2.weight(.semibold)).foregroundStyle(SalaryStyle.onAccent)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(SalaryStyle.accent, in: Capsule())
                }
                Text(card.title).font(.subheadline.weight(.semibold))
                Text(SalaryDisplay.whole(card.tax))
                    .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(card.best ? SalaryStyle.net : SalaryStyle.text).lineLimit(1).minimumScaleFactor(0.6)
                Text("全年个税合计（元）").font(.caption2).foregroundStyle(SalaryStyle.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    fact("年终奖税额", SalaryDisplay.whole(card.bonusTax))
                    fact("工资部分税额", SalaryDisplay.whole(card.salaryTax))
                    fact("全年到手", SalaryDisplay.whole(card.net), color: SalaryStyle.net)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(card.best ? SalaryStyle.tint : SalaryStyle.input, in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(card.best ? SalaryStyle.accent.opacity(0.5) : SalaryStyle.line, lineWidth: card.best ? 1.2 : 0.7) }
                .accessibilityElement(children: .combine).accessibilityIdentifier("salary-bonus-" + card.id)
        }
    }

    private var offerPanel: some View {
        SalaryPanel {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("两份 offer").font(.headline); Spacer(minLength: 8); syncButton
                }
                VStack(alignment: .leading, spacing: 10) { Text("两份 offer").font(.headline); syncButton }
            }
            Text("A 默认取当前测算参数，B 可以随便改。").font(.caption).foregroundStyle(SalaryStyle.secondary)
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) { offerCards }
            } else {
                HStack(alignment: .top, spacing: 12) { offerCards }
            }
            deltaBox(SalaryPresentation.offerDelta(offerAResult, offerBResult), symbol: "arrow.left.arrow.right",
                     flat: abs(offerBResult["main"]["net"].double - offerAResult["main"]["net"].double) < 1,
                     identifier: "salary-offer-delta")
            SalaryBarList(bars: SalaryPresentation.offerBars(offerAResult, offerBResult))
        }.accessibilityElement(children: .contain).accessibilityIdentifier("salary-offers")
    }
    private var syncButton: some View {
        Button(action: syncOffer) {
            Label("A 同步当前", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.medium))
                .padding(.horizontal, 11).frame(minHeight: 44).background(SalaryStyle.tint, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("salary-sync-offer")
    }
    private var offerCards: some View {
        ForEach(["a", "b"], id: \.self) { key in
            let binding = key == "a" ? $offerA : $offerB
            let result = key == "a" ? offerAResult : offerBResult
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(key.uppercased()).font(.caption.weight(.bold)).foregroundStyle(SalaryStyle.onAccent)
                        .frame(width: 22, height: 22).background(key == "a" ? SalaryStyle.secondary : SalaryStyle.accent, in: Circle())
                    Text(key == "a" ? "当前方案" : "另一份 offer").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                Text(SalaryPresentation.offerSubtitle(result)).font(.caption2).foregroundStyle(SalaryStyle.secondary)
                SalaryNumberField(title: "税前月薪", value: offerText(binding, "gross"), identifier: "salary-offer-\(key)-gross")
                SalaryNumberField(title: "年终奖", value: offerText(binding, "bonus"), identifier: "salary-offer-\(key)-bonus")
                SalaryNumberField(title: "公积金 %", value: offerText(binding, "fundRate"), identifier: "salary-offer-\(key)-fund")
                SalaryMenu(title: "城市", value: binding.wrappedValue["city"].text, options: cityOptions,
                           select: { binding.wrappedValue["city"] = .string($0) }, identifier: "salary-offer-\(key)-city")
                VStack(alignment: .leading, spacing: 4) {
                    Text("全年到手").font(.caption2).foregroundStyle(SalaryStyle.secondary)
                    Text("¥" + SalaryDisplay.whole(result["main"]["net"].double))
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(key == "a" ? SalaryStyle.text : SalaryStyle.net).lineLimit(1).minimumScaleFactor(0.6)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("salary-offer-\(key)-net")
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(SalaryStyle.input, in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(SalaryStyle.line, lineWidth: 0.7) }
        }
    }

    private var raisePanel: some View {
        SalaryPanel {
            SalaryPanelHeading(title: "涨薪能落袋多少", subtitle: "月薪加一笔，社保、公积金和个税会跟着吃掉一部分。",
                               pill: "落袋 " + SalaryDisplay.percent(marginal["keepRate"].double))
            SalarySlider(title: "月薪增加", value: $raiseDelta, range: 500...10000, step: 500,
                         readout: "¥" + SalaryDisplay.whole(raiseDelta), identifier: "salary-raise")
            SalaryMetricRow(metrics: presentation.raiseMetrics(marginal, delta: raiseDelta))
        }.accessibilityElement(children: .contain).accessibilityIdentifier("salary-raise-panel")
    }

    private var yearPanel: some View {
        SalaryPanel {
            SalaryPanelHeading(title: "全年这笔钱去哪了",
                               pill: "税前 ¥" + SalaryDisplay.whole(presentation.main["gross"].double + presentation.main["bonus"].double))
            SalaryBarList(bars: presentation.yearBars)
            Text(presentation.yearNote).font(.caption2).foregroundStyle(SalaryStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("salary-year")
    }

    private func fact(_ title: String, _ value: String, color: Color = SalaryStyle.text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption2).foregroundStyle(SalaryStyle.secondary)
            Spacer(minLength: 6)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
    }
    private func deltaBox(_ text: String, symbol: String, flat: Bool, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(flat ? SalaryStyle.secondary : SalaryStyle.accent)
                .accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(SalaryStyle.text).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(flat ? SalaryStyle.input : SalaryStyle.tint, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }
    private func offerText(_ binding: Binding<JSONValue>, _ key: String) -> Binding<String> {
        Binding(get: { binding.wrappedValue[key].text }, set: { binding.wrappedValue[key] = .string($0) })
    }
}