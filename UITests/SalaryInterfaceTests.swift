import XCTest

final class SalaryInterfaceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(dark: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "list", "--preview-module", "salary", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-appearance", dark ? "dark" : "light"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["salary-scene-calc"].waitForExistence(timeout: 20))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.scrollViews["salary-scroll"].swipeUp()
        }
        XCTFail("Salary control was not reachable: \(element)")
    }
    private func top(_ app: XCUIApplication) {
        for _ in 0..<12 {
            if app.descendants(matching: .any)["salary-net"].isHittable { return }
            app.scrollViews["salary-scroll"].swipeDown()
        }
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func net(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["salary-net"] }
    private func tapMenu(_ menu: XCUIElement) {
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // SwiftUI Menu's AX activation point can be {-1,-1} on this simulator; tap its real centre.
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let count = (field.value as? String ?? "").count
        if count > 0 { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count)) }
        field.typeText(text)
    }

    func testHeroRecalculatesAndEverySceneStaysReachable() {
        let app = launch()
        XCTAssertTrue(net(app).waitForExistence(timeout: 10))
        capture(app, "salary-calc-light")
        let before = net(app).label
        let gross = app.textFields["salary-gross"]
        reveal(gross, app: app); replace(gross, with: "45000")
        Thread.sleep(forTimeInterval: 0.8)
        top(app)
        XCTAssertNotEqual(net(app).label, before, "Editing the salary must recalculate the payslip hero")
        capture(app, "salary-calc-edited")
        XCTAssertTrue(app.buttons["salary-scene-slip"].isHittable)
        app.buttons["salary-scene-slip"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["salary-receipt"].waitForExistence(timeout: 5))
        capture(app, "salary-slip-light")
        app.buttons["salary-scene-compare"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["salary-bonus-compare"].waitForExistence(timeout: 5))
        capture(app, "salary-compare-light")
        XCTAssertTrue(app.buttons["salary-scene-calc"].isHittable)
        app.buttons["salary-scene-calc"].tap()
        XCTAssertTrue(net(app).waitForExistence(timeout: 5))
    }

    func testSlipExplainsTaxAndEmployerCost() {
        let app = launch()
        app.buttons["salary-scene-slip"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["salary-receipt"].waitForExistence(timeout: 5))
        let december = app.buttons["salary-month-12"]
        reveal(december, app: app); december.tap()
        XCTAssertTrue(app.staticTexts["12 月工资条"].waitForExistence(timeout: 5))
        let employer = app.switches["salary-employer-toggle"]
        reveal(employer, app: app); employer.tap()
        XCTAssertTrue(app.staticTexts["单位缴纳"].waitForExistence(timeout: 5))
        capture(app, "salary-slip-employer")
        let formula = app.staticTexts["salary-tax-formula"]
        reveal(formula, app: app)
        XCTAssertTrue(formula.label.contains("本月预扣"))
        capture(app, "salary-slip-tax")
        let copy = app.buttons["salary-copy"]
        reveal(copy, app: app); copy.tap()
        XCTAssertTrue(app.descendants(matching: .any)["salary-toast"].waitForExistence(timeout: 3))
    }

    func testCompareShowsBonusTrapOfferAndRaise() {
        let app = launch(dark: true)
        capture(app, "salary-calc-dark")
        app.buttons["salary-scene-compare"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["salary-bonus-compare"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["salary-bonus-separate"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["salary-bonus-delta"].exists)
        capture(app, "salary-compare-dark")
        let sync = app.buttons["salary-sync-offer"]
        reveal(sync, app: app); sync.tap()
        XCTAssertTrue(app.descendants(matching: .any)["salary-toast"].waitForExistence(timeout: 3))
        let raise = app.sliders["salary-raise"]
        reveal(raise, app: app)
        raise.adjust(toNormalizedSliderPosition: 0.5)
        Thread.sleep(forTimeInterval: 0.8)
        capture(app, "salary-raise-dark")
        let year = app.descendants(matching: .any)["salary-year"]
        reveal(year, app: app)
        capture(app, "salary-year-dark")
    }

    func testSheetsApplyPresetsAndJumpToAMonth() {
        let app = launch()
        tapMenu(app.buttons["salary-plans"])
        app.buttons["示例方案与本机方案"].tap()
        XCTAssertTrue(app.navigationBars["示例方案"].waitForExistence(timeout: 5))
        capture(app, "salary-plans-sheet")
        app.buttons["salary-preset-1"].tap()
        XCTAssertTrue(app.navigationBars["示例方案"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["salary-draft-status"].label.contains("北京"))
        capture(app, "salary-preset-applied")
        let detail = app.buttons["salary-year-detail"]
        reveal(detail, app: app); detail.tap()
        XCTAssertTrue(app.navigationBars["全年逐月明细"].waitForExistence(timeout: 5))
        capture(app, "salary-year-sheet")
        app.buttons["salary-year-6"].tap()
        XCTAssertTrue(app.buttons["salary-month-button"].label.contains("6 月到手"))
        let about = app.buttons["salary-about"]
        reveal(about, app: app); about.tap()
        XCTAssertTrue(app.navigationBars["怎么算的"].waitForExistence(timeout: 5))
        capture(app, "salary-explain-sheet")
        app.buttons["salary-sheet-done"].tap()
        XCTAssertTrue(app.navigationBars["怎么算的"].waitForNonExistence(timeout: 5))
    }

    func testAccessibilityTextKeepsScenesAndParametersReachable() {
        let app = launch(largeText: true)
        XCTAssertTrue(net(app).waitForExistence(timeout: 10))
        capture(app, "salary-calc-large")
        let gross = app.textFields["salary-gross"]
        reveal(gross, app: app)
        XCTAssertTrue(gross.isHittable)
        capture(app, "salary-controls-large")
        app.buttons["salary-scene-slip"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["salary-receipt"].waitForExistence(timeout: 5))
        capture(app, "salary-slip-large")
        app.buttons["salary-scene-compare"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["salary-bonus-compare"].waitForExistence(timeout: 5))
        capture(app, "salary-compare-large")
        XCTAssertTrue(app.buttons["salary-scene-calc"].isHittable)
    }
}