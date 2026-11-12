import XCTest
import UIKit
@testable import ClipStudio

final class SalaryTests: XCTestCase {
    @MainActor private func engine() throws -> SalaryEngine { try SalaryEngine() }
    @MainActor private func presentation(_ draft: JSONValue, month: Int = 1, withBonus: Bool = true) throws -> SalaryPresentation {
        let e = try engine()
        return SalaryPresentation(result: try e.compute(draft), tables: try e.call("tables"), month: month, withBonus: withBonus)
    }

    func testSceneIconsExistInTheSystemSymbolCatalog() {
        for scene in SalaryScene.allCases {
            XCTAssertNotNil(UIImage(systemName: scene.symbol), "Missing navigation symbol: \(scene.symbol)")
            XCTAssertNotNil(UIImage(systemName: scene.selectedSymbol), "Missing selected symbol: \(scene.selectedSymbol)")
        }
    }

    @MainActor func testDemoMatchesTheApprovedDesignNumbers() throws {
        let e = try engine()
        let defaults = try e.call("defaults")
        let result = try e.compute(defaults)
        XCTAssertEqual(result["main"]["rows"][0]["net"].double, 25953, accuracy: 0.001)
        XCTAssertEqual(result["main"]["net"].double, 352170, accuracy: 0.001)
        XCTAssertEqual(result["main"]["avgNet"].double, 29347.5, accuracy: 0.001)
        XCTAssertEqual(result["main"]["tax"].double, 18840, accuracy: 0.001)
        XCTAssertEqual(result["main"]["bonusTax"].double, 5790, accuracy: 0.001)
        XCTAssertEqual(result["bonusCompare"]["saving"].double, 6210, accuracy: 0.001)
        XCTAssertEqual(result["bonusCompare"]["best"].text, "separate")
        XCTAssertEqual(result["raise"]["yearGain"].double, 7920, accuracy: 0.001)

        let view = SalaryPresentation(result: result, tables: try e.call("tables"), month: 1)
        XCTAssertEqual(view.net, 25953, accuracy: 0.001)
        XCTAssertEqual(view.monthTitle, "1 月到手")
        XCTAssertEqual(view.badge, "税率档 3%")
        XCTAssertEqual(view.metrics.map(\.value), ["35.22", "29,348", "24,630"])
        XCTAssertEqual(view.employerCost, 42611.2, accuracy: 0.001)
        XCTAssertEqual(view.flow.last?.title, "实发到手")
        XCTAssertEqual(view.shares.first?.kind, .net)
        XCTAssertTrue(view.insight.contains("6,210"))
    }

    @MainActor func testCumulativeWithholdingJumpsAndNeverShowsNegativeZero() throws {
        let e = try engine()
        var draft = try e.call("defaults")
        for (key, value) in ["city": JSONValue.string("custom"), "baseMode": .string("custom"), "fundMode": .string("custom"),
                             "elder": .string("none"), "housing": .string("none")] { draft[key] = value }
        for key in ["gross", "bonus", "children", "infants", "pension", "otherPre", "afterTax"] { draft[key] = .number(key == "gross" ? 10000 : 0) }
        draft["customBase"] = .number(0); draft["customFundBase"] = .number(0); draft["fundRate"] = .number(0)
        let result = try e.compute(draft)
        XCTAssertEqual(result["main"]["rows"][0]["tax"].double, 150, accuracy: 0.001)
        XCTAssertEqual(result["main"]["rows"][7]["tax"].double, 430, accuracy: 0.001)
        XCTAssertEqual(result["main"]["taxTotal"].double, 3480, accuracy: 0.001)
        XCTAssertEqual(result["main"]["net"].double, 116520, accuracy: 0.001)

        let tables = try e.call("tables")
        let first = SalaryPresentation(result: result, tables: tables, month: 1)
        XCTAssertEqual(first.previouslyPaid, 0)
        XCTAssertEqual(first.taxSteps.first { $0.id == "prevPaid" }?.amount, 0)
        XCTAssertFalse(first.slipText(trap: .null).contains("−0.00"))
        let eighth = SalaryPresentation(result: result, tables: tables, month: 8)
        XCTAssertTrue(eighth.badgeIsJump)
        XCTAssertEqual(eighth.badge, "本月跳档 10%")
        XCTAssertEqual(eighth.taxSteps.last?.amount, 430)
        XCTAssertTrue(eighth.taxFormula.contains("本月预扣"))
    }

    @MainActor func testBonusBracketsBlindZonesAndModeComparison() throws {
        let e = try engine()
        let defaults = try e.call("defaults")
        var lower = defaults; lower["bonus"] = .number(36000)
        var upper = defaults; upper["bonus"] = .number(36001)
        let lowerTax = try e.compute(lower)["separate"]["bonusTax"].double
        let upperTax = try e.compute(upper)["separate"]["bonusTax"].double
        XCTAssertEqual(lowerTax, 1080, accuracy: 0.001)
        XCTAssertEqual(upperTax, 3390.1, accuracy: 0.001)
        XCTAssertLessThan(36001 - upperTax, 36000 - lowerTax)

        XCTAssertEqual(try e.bonusTrap(38500)["state"].text, "blind")
        XCTAssertEqual(try e.bonusTrap(38500)["edge"].double, 36000)
        XCTAssertEqual(try e.bonusTrap(60000)["state"].text, "below")
        XCTAssertEqual(try e.bonusTrap(60000)["next"].double, 144000)
        XCTAssertEqual(try e.bonusTrap(1_200_000)["state"].text, "top")
        XCTAssertEqual(try e.bonusTrap(0)["state"].text, "empty")
        XCTAssertTrue(SalaryPresentation.trapText(try e.bonusTrap(38500), bonus: 38500).contains("跳档盲区"))

        var merged = defaults; merged["bonusMode"] = .string("merged")
        let view = try presentation(merged)
        XCTAssertEqual(view.bonusModeTitle, "并入综合所得")
        XCTAssertEqual(view.bonusCards.map(\.id), ["separate", "merged"])
        XCTAssertTrue(view.bonusCards.first?.best == true)
        XCTAssertFalse(view.bonusDelta.contains("自动择优"))
    }

    @MainActor func testInsuranceClampsAndSpecialDeductionStandards() throws {
        let e = try engine()
        let defaults = try e.call("defaults")
        var high = defaults; high["gross"] = .number(37000)
        var low = defaults; low["gross"] = .number(5000)
        XCTAssertEqual(try e.compute(high)["insurance"]["base"].double, 36921, accuracy: 0.001)
        XCTAssertTrue(try e.compute(high)["insurance"]["capped"].flag)
        XCTAssertEqual(try e.compute(low)["insurance"]["base"].double, 7384, accuracy: 0.001)
        XCTAssertTrue(try e.compute(low)["insurance"]["floored"].flag)
        XCTAssertTrue(try presentation(high).notices.contains { $0.contains("封顶") })

        var full = defaults
        full["children"] = .integer(2); full["infants"] = .integer(1); full["elder"] = .string("only")
        full["housing"] = .string("loan"); full["study"] = .bool(true); full["pension"] = .number(1000)
        XCTAssertEqual(try e.compute(full)["special"]["total"].double, 11400, accuracy: 0.001)
        var capped = defaults; capped["pension"] = .number(5000)
        XCTAssertEqual(try e.compute(capped)["special"]["total"].double, 7500, accuracy: 0.001)
    }

    @MainActor func testChartModesSplitBonusOutOfTheSalaryBars() throws {
        let all = try presentation(try engine().call("defaults"), month: 12)
        XCTAssertEqual(all.chartBars[11].net, 77630, accuracy: 0.001)
        XCTAssertEqual(all.chartBars[11].tax, 8770, accuracy: 0.001)
        XCTAssertEqual(all.bonusMonth, 12)
        XCTAssertEqual(all.chartUnit, 10000)
        let salary = try presentation(try engine().call("defaults"), month: 12, withBonus: false)
        XCTAssertEqual(salary.chartBars[11].net, 23420, accuracy: 0.001)
        XCTAssertEqual(salary.chartBars[11].tax, 2980, accuracy: 0.001)
        XCTAssertEqual(salary.chartBars.filter { $0.jumpTo != nil }.map(\.month), [3, 10])
    }

    @MainActor func testInactiveMonthsAreMarkedAndReceiptStaysHonest() throws {
        let e = try engine()
        var draft = try e.call("defaults")
        draft["startMonth"] = .integer(7)
        let view = SalaryPresentation(result: try e.compute(draft), tables: try e.call("tables"), month: 3)
        XCTAssertFalse(view.active)
        XCTAssertEqual(view.badge, "未入职")
        XCTAssertEqual(view.receiptBadge, "未入职")
        XCTAssertEqual(view.net, 0)
        XCTAssertEqual(view.employerTotal, 0)
        XCTAssertTrue(view.taxFormula.contains("尚未入职"))
        XCTAssertEqual(view.deductions.first?.title, "本月无扣款")
        XCTAssertEqual(view.activeMonths, 0)
    }

    func testOfferComparisonAndRaiseMetrics() {
        let a: JSONValue = .object(["main": .object(["net": .number(300000), "gross": .number(384000), "bonus": .number(60000), "fund": .number(26880), "avgNet": .number(25000)]),
                                      "city": .object(["name": .string("上海")])])
        var b = a
        b["main"]["net"] = .number(360000)
        b["main"]["gross"] = .number(456000)
        b["main"]["bonus"] = .number(90000)
        XCTAssertEqual(SalaryPresentation.offerSubtitle(a), "上海 · 月均 25,000")
        XCTAssertTrue(SalaryPresentation.offerDelta(a, a).contains("基本一样"))
        let delta = SalaryPresentation.offerDelta(a, b)
        XCTAssertTrue(delta.contains("多到手 ¥60,000"))
        XCTAssertTrue(delta.contains("税前差 102,000"))
        XCTAssertEqual(SalaryPresentation.offerBars(a, b).map(\.ratio), [300000.0 / 360000.0, 1])
        let marginal: JSONValue = .object(["yearGain": .number(7920), "monthGain": .number(660), "keepRate": .number(0.66)])
        let view = SalaryPresentation(result: .null, tables: .null, month: 1)
        XCTAssertEqual(view.raiseMetrics(marginal, delta: 1000).map(\.value), ["7,920", "660", "4,080"])
    }

    @MainActor func testSlipTextCarriesReceiptTaxStepsAndPolicyNote() throws {
        let e = try engine()
        let view = SalaryPresentation(result: try e.compute(try e.call("defaults")), tables: try e.call("tables"), month: 12)
        let text = view.slipText(trap: try e.bonusTrap(60000))
        XCTAssertTrue(text.contains("12 月工资条（含年终奖）"))
        XCTAssertTrue(text.contains("全年一次性奖金"))
        XCTAssertTrue(text.contains("实发到手：¥77,630.00"))
        XCTAssertTrue(text.contains("本月应预扣"))
        XCTAssertTrue(text.contains("年终奖两种算法"))
        XCTAssertFalse(text.contains("2027"))
        XCTAssertTrue(text.contains("示例值"))
    }

    @MainActor func testPresetsAndLocalModuleRegistration() throws {
        let presets = SalaryPresets.builtIn(try engine().call("defaults"))
        XCTAssertEqual(presets.count, 5)
        XCTAssertEqual(presets.map(\.name).first, "上海 · 一娃租房")
        XCTAssertEqual(presets[2].data["startMonth"].int, 7)
        XCTAssertEqual(presets[4].data["city"].text, "chengdu")
        XCTAssertEqual(WorkspaceApp(rawValue: "salary"), .salary)
        XCTAssertEqual(WorkspaceModule(key: "salary", name: "到手工资", desc: "", hidden: false).icon, "yensign.circle")
        XCTAssertTrue(WorkspaceModule(key: "salary", name: "到手工资", desc: "", hidden: false).available)
    }

    func testDisplayFormattingKeepsSignsAndUnits() {
        XCTAssertEqual(SalaryDisplay.money(25953), "25,953.00")
        XCTAssertEqual(SalaryDisplay.signed(-150), "−150.00")
        XCTAssertEqual(SalaryDisplay.signed(0), "0.00")
        XCTAssertEqual(SalaryDisplay.wan(352170), "35.22")
        XCTAssertEqual(SalaryDisplay.percent(0.66), "66.0%")
        XCTAssertEqual(SalaryDisplay.rate(0.1), "10%")
        XCTAssertEqual(SalaryDisplay.compact(25953), "26.0k")
        XCTAssertEqual(SalaryDisplay.money(.nan), "—")
    }
}