import SwiftUI

struct SalarySlipScene: View {
    let presentation: SalaryPresentation
    @Binding var showEmployer: Bool
    let selectMonth: (Int) -> Void
    let copy: () -> Void
    let export: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SalaryMonthStrip(rows: presentation.rows, selection: presentation.month, select: selectMonth)
            receipt
            taxPanel
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(spacing: 10) { actions }
            }
        }
    }

    private var receipt: some View {
        SalaryPanel {
            SalaryPanelHeading(title: presentation.receiptTitle, subtitle: presentation.receiptSubtitle,
                               pill: presentation.receiptBadge,
                               pillKind: presentation.row["bonus"].double > 0 ? .fund : nil)
            section("应发项目") { ForEach(presentation.income) { SalaryReceiptLine(line: $0) } }
            section("个人扣除") { ForEach(presentation.deductions) { SalaryReceiptLine(line: $0) } }
            Toggle(isOn: $showEmployer) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("显示单位缴纳部分").font(.subheadline)
                    Text("不影响你的到手，只影响公司成本").font(.caption2).foregroundStyle(SalaryStyle.secondary)
                }
            }.tint(SalaryStyle.accent).accessibilityIdentifier("salary-employer-toggle")
            if showEmployer {
                section("单位缴纳") { ForEach(presentation.employer) { SalaryReceiptLine(line: $0) } }
            }
            Divider().overlay(SalaryStyle.line)
            HStack(alignment: .firstTextBaseline) {
                Text("实发到手").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("¥" + SalaryDisplay.money(presentation.net))
                    .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(SalaryStyle.net).lineLimit(1).minimumScaleFactor(0.6)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("salary-receipt-net")
        }.accessibilityIdentifier("salary-receipt")
    }

    private var taxPanel: some View {
        SalaryPanel {
            SalaryPanelHeading(title: "本月个税怎么来的", pill: presentation.taxRatePill, pillKind: .tax)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(presentation.taxSteps) { SalaryReceiptLine(line: $0) }
            }.accessibilityIdentifier("salary-tax-steps")
            Text(presentation.taxFormula).font(.caption).foregroundStyle(SalaryStyle.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityIdentifier("salary-tax-formula")
        }.accessibilityIdentifier("salary-tax")
    }

    private var actions: some View {
        SalaryPrimaryButton(title: "复制工资条", symbol: "doc.on.doc", action: copy, filled: false, identifier: "salary-copy")
        SalaryPrimaryButton(title: "导出文本", symbol: "square.and.arrow.up", action: export, identifier: "salary-download")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(SalaryStyle.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }
}