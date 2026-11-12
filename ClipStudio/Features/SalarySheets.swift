import SwiftUI

private struct SalaryTableRow: View {
    let cells: [String]
    var highlight = false
    var header = false
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell).font(header ? .caption2.weight(.semibold) : .caption).monospacedDigit()
                    .foregroundStyle(header ? SalaryStyle.secondary : SalaryStyle.text)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
            }
        }.padding(.vertical, 7).padding(.horizontal, 10)
            .background(highlight ? SalaryStyle.tint : .clear, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
}

struct SalarySheetView: View {
    let sheet: SalarySheet
    let presentation: SalaryPresentation
    let presets: [SalaryPreset]
    let activePreset: Int?
    let cities: [JSONValue]
    let tables: JSONValue
    let trap: JSONValue
    let monthlyNet: (JSONValue) -> Double
    let apply: (Int) -> Void
    let savePreset: () -> Void
    let selectMonth: (Int) -> Void
    let copy: () -> Void
    let export: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch sheet {
                    case .plans: plans
                    case .explain: explain
                    case .standards: standards
                    case .cities: cityList
                    case .year: year
                    case .month: months
                    case .export: exportText
                    }
                }.frame(maxWidth: 700).padding(.horizontal, 20).padding(.vertical, 18).frame(maxWidth: .infinity)
            }.background(SalaryStyle.background).accessibilityIdentifier("salary-sheet-" + sheet.rawValue)
                .navigationTitle(sheet.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }.accessibilityIdentifier("salary-sheet-done")
                    }
                }
        }.foregroundStyle(SalaryStyle.text).tint(SalaryStyle.accent)
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("点一下即可套用。方案只存在本机，不上传服务器。").font(.caption).foregroundStyle(SalaryStyle.secondary)
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                Button { apply(index) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name).font(.subheadline.weight(.semibold))
                            Text(preset.desc).font(.caption2).foregroundStyle(SalaryStyle.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("¥" + SalaryDisplay.whole(monthlyNet(preset.data)) + "/月")
                            .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(SalaryStyle.accent)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(activePreset == index ? SalaryStyle.tint : SalaryStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(activePreset == index ? SalaryStyle.accent.opacity(0.5) : SalaryStyle.line, lineWidth: 0.7) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("salary-preset-\(index)")
            }
            SalaryPrimaryButton(title: "把当前参数存为本机方案", symbol: "doc.badge.plus", action: savePreset, identifier: "salary-save-preset")
        }
    }

    private var explain: some View {
        VStack(alignment: .leading, spacing: 14) {
            block("1 · 每月到手", "到手 = 税前月薪 + 当月年终奖 − 社保个人部分 − 公积金个人部分 − 当月预扣个税 − 税后扣款。公积金虽然扣走，但仍进你的个人账户。")
            block("2 · 累计预扣预缴（工资个税）", "本月预扣 =（累计收入 − 累计 5,000/月 − 累计三险一金 − 累计专项附加 − 累计其他扣除）× 税率 − 速算扣除数 − 此前已预扣。所以年初税少、跳档后税多，工资条上的到手会逐月变小。")
            table(caption: "综合所得年度税率表（高亮为当前累计所在档）", head: ["累计应纳税所得额", "税率", "速算扣除"],
                  rows: bracketRows(tables["year"].array),
                  highlights: tables["year"].array.enumerated().map { bracketHit(tables["year"].array, index: $0.offset, value: presentation.row["cumTaxable"].double) })
            block("3 · 年终奖单独计税", "奖金 ÷ 12 找下表档位，税额 = 奖金 × 税率 − 速算扣除数。一年只能用一次，政策执行至 2027-12-31。也可以选择并入综合所得，页面会自动比较两者。")
            table(caption: "按月换算后的综合所得税率表", head: ["奖金 ÷ 12", "税率", "速算扣除"],
                  rows: bracketRows(tables["month"].array))
            block("4 · 口径与边界", "只算居民个人工资薪金与全年一次性奖金，不含劳务报酬、股权激励、经营所得；工伤、生育保险个人不缴；社保与公积金基数按当地上下限截断，公积金比例 0–12%；不含公益性捐赠、大病医疗汇算扣除与年度汇算补退税；城市预设为示例值，须按当地社保年度公布数据核对。")
        }
    }
    private func bracketRows(_ brackets: [JSONValue]) -> [[String]] {
        brackets.enumerated().map { index, bracket in
            let lower = index > 0 ? brackets[index - 1][0].double : 0
            let upper: Double? = bracket[0].isNull ? nil : bracket[0].double
            let label = upper.map { SalaryDisplay.whole(lower) + " – " + SalaryDisplay.whole($0) } ?? "超过 " + SalaryDisplay.whole(lower)
            return [label, SalaryDisplay.rate(bracket[1].double), SalaryDisplay.whole(bracket[2].double)]
        }
    }
    private func bracketHit(_ brackets: [JSONValue], index: Int, value: Double) -> Bool {
        let lower = index > 0 ? brackets[index - 1][0].double : 0
        let upper = brackets[index][0].isNull ? Double.infinity : brackets[index][0].double
        return value > lower && value <= upper
    }

    private var standards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按现行标准列示，实际以个人所得税 App 中填报的额度为准。").font(.caption).foregroundStyle(SalaryStyle.secondary)
            table(caption: nil, head: ["项目", "标准"], rows: [
                ["子女教育", "每孩 2,000 元/月"], ["3 岁以下婴幼儿照护", "每孩 2,000 元/月"],
                ["赡养老人", "独生 3,000 元/月"], ["住房贷款利息", "1,000 元/月"],
                ["住房租金", "1,500 / 1,100 / 800"], ["继续教育", "学历 400 元/月"], ["个人养老金", "最高 1,000 元/月"]
            ])
            Text("子女教育含学前教育至全日制学历教育；婴幼儿照护可由父母一方或双方分摊；非独生赡养老人分摊每人不超过 1,500；房贷利息限首套、最长 240 个月；租金与房贷利息二选一；继续教育同一学历最长 48 个月，职业资格 3,600 元/年；个人养老金全年 12,000 元限额，领取时另计税。")
                .font(.caption2).foregroundStyle(SalaryStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("下表是内置的示例区间，量级参考各地社保年度公布数据，不是实时口径。").font(.caption).foregroundStyle(SalaryStyle.secondary)
            table(caption: nil, head: ["城市", "社保下限", "社保上限", "公积金上限"],
                  rows: cities.map { [$0["name"].text, SalaryDisplay.whole($0["floor"].double), SalaryDisplay.whole($0["ceil"].double), SalaryDisplay.whole($0["fundCeil"].double)] },
                  highlights: cities.map { $0["key"].text == presentation.city["key"].text })
            block("个人缴纳比例", "养老 8%，失业 0.5%，工伤 / 生育个人不缴；医疗各地不同，北京另加大病 3 元/月；公积金 0–12%，单位与个人同比例。")
        }
    }

    private var year: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("点任意一行切到那个月的工资条。单位：元。").font(.caption).foregroundStyle(SalaryStyle.secondary)
            VStack(spacing: 2) {
                SalaryTableRow(cells: ["月份", "到手", "五险一金", "个税", "税率档"], header: true)
                ForEach(Array(presentation.rows.enumerated()), id: \.offset) { index, row in
                    Button { selectMonth(row["month"].int) } label: {
                        SalaryTableRow(cells: ["\(row["month"].int) 月", SalaryDisplay.whole(row["net"].double),
                                               SalaryDisplay.whole(row["social"].double + row["fund"].double),
                                               SalaryDisplay.whole(row["taxTotal"].double), SalaryDisplay.rate(row["rate"].double)],
                                       highlight: row["month"].int == presentation.month)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("salary-year-\(index + 1)")
                }
                SalaryTableRow(cells: ["全年合计", SalaryDisplay.whole(presentation.main["net"].double),
                                       SalaryDisplay.whole(presentation.main["social"].double + presentation.main["fund"].double),
                                       SalaryDisplay.whole(presentation.main["taxTotal"].double), "—"], highlight: true)
            }
        }
    }

    private var months: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("切换主卡与工资条显示的月份。").font(.caption).foregroundStyle(SalaryStyle.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                ForEach(Array(presentation.rows.enumerated()), id: \.offset) { _, row in
                    let month = row["month"].int
                    Button { selectMonth(month) } label: {
                        VStack(spacing: 3) {
                            Text("\(month) 月").font(.subheadline.weight(presentation.month == month ? .semibold : .regular))
                            Text(row["active"].flag ? SalaryDisplay.compact(row["net"].double) : "—")
                                .font(.caption2).monospacedDigit().foregroundStyle(SalaryStyle.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 56)
                            .background(presentation.month == month ? SalaryStyle.tint : SalaryStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(presentation.month == month ? SalaryStyle.accent.opacity(0.5) : SalaryStyle.line, lineWidth: 0.7) }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("salary-pick-month-\(month)")
                }
            }
        }
    }

    private var exportText: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("纯文本工资条，可直接粘进备忘录或聊天窗口。").font(.caption).foregroundStyle(SalaryStyle.secondary)
            Text(presentation.slipText(trap: trap)).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(SalaryStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(SalaryStyle.line, lineWidth: 0.7) }
                .accessibilityIdentifier("salary-export-text")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { exportActions }
                VStack(spacing: 10) { exportActions }
            }
        }
    }
    private var exportActions: some View {
        SalaryPrimaryButton(title: "复制", symbol: "doc.on.doc", action: copy, filled: false, identifier: "salary-sheet-copy")
        SalaryPrimaryButton(title: "下载 .txt", symbol: "square.and.arrow.up", action: export, identifier: "salary-sheet-download")
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(text).font(.caption).foregroundStyle(SalaryStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func table(caption: String?, head: [String], rows: [[String]], highlights: [Bool]? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption { Text(caption).font(.caption2).foregroundStyle(SalaryStyle.secondary) }
            VStack(spacing: 2) {
                SalaryTableRow(cells: head, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    SalaryTableRow(cells: row, highlight: highlights?[index] ?? false)
                }
            }.padding(6).background(SalaryStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(SalaryStyle.line, lineWidth: 0.7) }
        }
    }
}