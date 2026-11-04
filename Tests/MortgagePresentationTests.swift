import XCTest
@testable import ClipStudio

final class MortgagePresentationTests: XCTestCase {
    @MainActor func testTrialSummaryUsesSelectedRepaymentMethod() throws {
        let engine = try MortgageEngine()
        var draft = try engine.call("defaults")["new"]
        draft["method"] = .string("principal")
        let result = try engine.calculate(kind: "new", data: draft)
        let view = MortgagePresentation(kind: "new", draft: draft, calculation: result)
        XCTAssertEqual(view.payment, result["principal"]["rows"][0]["payment"])
        XCTAssertEqual(view.paymentTitle, "预计首月还款")
        XCTAssertEqual(view.metrics.map(\.title), ["贷款总额", "利息总额", "累计还款"])
        XCTAssertEqual(view.chartSeries.map(\.title), ["等额本息", "等额本金"])
        XCTAssertEqual(view.chartSeries[0].points.first?.balance, result["total"].double)
    }
    @MainActor func testPrepaymentSummaryUsesFirstPaymentAfterExtraPayment() throws {
        let engine = try MortgageEngine()
        let draft = try engine.call("defaults")["new"]
        let result = try engine.calculate(kind: "new", data: draft)
        let view = MortgagePresentation(kind: "new", draft: draft, calculation: result, prepayment: true, strategy: "payment")
        XCTAssertTrue(view.hasPrepayment)
        XCTAssertEqual(view.payment, result["payment"]["rows"][result["after"].int]["payment"])
        XCTAssertLessThan(view.payment.double, result["base"]["rows"][0]["payment"].double)
        XCTAssertEqual(view.savedMonths(for: "payment"), 0)
        XCTAssertGreaterThan(view.savedInterest(for: "payment").double, 0)
        XCTAssertEqual(view.actualPrepayment.double, 200_000, accuracy: 0.001)
        XCTAssertFalse(view.metadata.contains(where: { $0.hasPrefix("计划 ") }))
    }
    @MainActor func testPayingOffEarlyShowsZeroFuturePayment() throws {
        let engine = try MortgageEngine()
        var draft = try engine.call("defaults")["new"]
        draft["preAmount"] = .number(1000)
        let result = try engine.calculate(kind: "new", data: draft)
        let view = MortgagePresentation(kind: "new", draft: draft, calculation: result, prepayment: true)
        XCTAssertEqual(result["term"]["rows"].array.count, result["after"].int)
        XCTAssertEqual(view.payment.double, 0)
        XCTAssertEqual(view.chartSeries[1].balance(at: view.chartMonths), 0)
        XCTAssertEqual(view.actualPrepayment, result["term"]["rows"][result["after"].int - 1]["prepay"])
        XCTAssertLessThan(view.actualPrepayment.double, draft["preAmount"].double * 10_000)
        XCTAssertEqual(view.metadata.first, "实际提前还 \(MortgageDisplay.wan(view.actualPrepayment)) 万元")
        XCTAssertTrue(view.metadata.contains("计划 1,000 万元"))
    }
    @MainActor func testCombinationDistinguishesTargetContractFromWholePlan() throws {
        let engine = try MortgageEngine()
        var draft = try engine.call("defaults")["new"]
        draft["type"] = .string("combo")
        let result = try engine.calculate(kind: "new", data: draft)
        let view = MortgagePresentation(kind: "new", draft: draft, calculation: result, prepayment: true)
        XCTAssertGreaterThan(result["savedMonths"].int, 0)
        XCTAssertEqual(result["base"]["months"], result["term"]["months"])
        XCTAssertEqual(view.savedMonths(for: "term"), result["savedMonths"].int)
        XCTAssertEqual(view.monthsTitle, "目标贷款缩短")
        XCTAssertTrue(view.insight.contains("整体结清时间可能不变"))
    }
    @MainActor func testImmediateCurrentPrepaymentIncludesUpfrontPrincipalInTotal() throws {
        let engine = try MortgageEngine()
        var draft = try engine.call("defaults")["current"]
        draft["parts"][0]["start"] = .string("2021-06-15")
        draft["extraWhen"] = .integer(0)
        draft["extraAmount"] = .number(10)
        let result = try engine.calculate(kind: "current", data: draft)
        let view = MortgagePresentation(kind: "current", draft: draft, calculation: result, prepayment: true, strategy: "payment")
        XCTAssertEqual(view.payment, result["payment"]["rows"][0]["payment"])
        XCTAssertEqual(view.repaymentTotal(for: "payment").double, result["total"].double + result["payment"]["interest"].double, accuracy: 0.001)
        XCTAssertEqual(view.repaymentTotal(for: "payment").double, result["payment"]["paid"].double + 100_000, accuracy: 0.02)
        XCTAssertEqual(view.chartSeries[1].points.first?.balance ?? -1, result["total"].double - 100_000, accuracy: 0.001)
        XCTAssertEqual(view.chartSeries[0].points.first?.balance ?? -1, result["total"].double, accuracy: 0.001)
    }
    @MainActor func testImmediateCombinationPrepaymentOnlyReducesSelectedBalance() throws {
        let engine = try MortgageEngine()
        var draft = try engine.call("defaults")["current"]
        var fund = try engine.call("part")
        fund["kind"] = .string("fund"); fund["amount"] = .number(60); fund["start"] = .string("2021-06-15")
        draft["parts"][0]["start"] = .string("2021-06-15")
        draft["parts"] = .array(draft["parts"].array + [fund])
        draft["extraPart"] = .integer(1); draft["extraWhen"] = .integer(0); draft["extraAmount"] = .number(1000)
        let result = try engine.calculate(kind: "current", data: draft)
        let view = MortgagePresentation(kind: "current", draft: draft, calculation: result, prepayment: true)
        let expected = result["total"].double - result["parts"][1]["balance"].double
        XCTAssertEqual(view.chartSeries[1].points.first?.balance ?? -1, expected, accuracy: 0.001)
        XCTAssertEqual(view.monthsTitle, "整体计划缩短")
        XCTAssertEqual(view.actualPrepayment.double, result["parts"][1]["balance"].double, accuracy: 0.001)
        XCTAssertTrue(view.metadata.contains("计划 1,000 万元"))
    }
    @MainActor func testDeferredCurrentPrepaymentUsesActualAppliedAmount() throws {
        let engine = try MortgageEngine()
        var draft = try engine.call("defaults")["current"]
        draft["parts"][0]["start"] = .string("2021-06-15")
        draft["extraWhen"] = .integer(12); draft["extraAmount"] = .number(1000)
        let result = try engine.calculate(kind: "current", data: draft)
        for strategy in ["term", "payment"] {
            let view = MortgagePresentation(kind: "current", draft: draft, calculation: result, prepayment: true, strategy: strategy)
            XCTAssertEqual(view.actualPrepayment, result[strategy]["rows"][11]["prepay"])
            XCTAssertGreaterThan(view.actualPrepayment.double, 0)
            XCTAssertLessThan(view.actualPrepayment.double, result["total"].double)
            XCTAssertTrue(view.metadata.contains("计划 1,000 万元"))
        }
    }
    func testChartDataRetainsZeroAndFinalPartialYear() {
        let rows: [JSONValue] = [.object(["n": .integer(1), "balance": .number(70)]), .object(["n": .integer(13), "balance": .number(0)])]
        let result: JSONValue = .object(["total": .number(100), "base": .object(["rows": .array(rows)])])
        let view = MortgagePresentation(kind: "current", draft: .null, calculation: result)
        XCTAssertEqual(view.chartDataMonths, [0, 12, 13])
        XCTAssertEqual(view.chartSeries[0].balance(at: 0), 100)
        XCTAssertEqual(view.chartSeries[0].balance(at: 13), 0)
        XCTAssertEqual(view.chartSeries[0].balance(at: 20), 0)
    }
    func testInvalidAndHugeYearInputsStaySafeToDisplay() {
        XCTAssertEqual(MortgageDisplay.periods(.string("1e300")), "—")
        XCTAssertEqual(MortgageDisplay.periods(.null), "—")
        XCTAssertEqual(MortgageDisplay.periods(.number(0)), "—")
        XCTAssertEqual(MortgageDisplay.periods(.number(30)), "360")
        XCTAssertEqual(MortgageDisplay.periods(.number(2.5)), "30")
    }
    func testMissingAmountsDoNotBecomeFakeZeros() {
        XCTAssertEqual(MortgageDisplay.money(.null), "—")
        XCTAssertEqual(MortgageDisplay.wan(.string("NaN")), "—")
        let view = MortgagePresentation(kind: "new", draft: .null, calculation: .null)
        XCTAssertTrue(view.payment.isNull)
        XCTAssertTrue(view.chartSeries.isEmpty)
        XCTAssertFalse(view.hasPrepayment)
    }
}
