import XCTest

final class MortgageInterfaceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(dark: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "list", "--preview-module", "mortgage", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-appearance", dark ? "dark" : "light"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["mortgage-scene-trial"].waitForExistence(timeout: 15))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.scrollViews["mortgage-scroll"].swipeUp()
        }
        XCTFail("Mortgage control was not reachable: \(element)")
    }
    private func top(_ app: XCUIApplication) {
        for _ in 0..<12 {
            if app.staticTexts["mortgage-monthly-payment"].isHittable { return }
            app.scrollViews["mortgage-scroll"].swipeDown()
        }
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testSummaryFirstAndNativeRepaymentComparison() {
        let app = launch()
        let summary = app.staticTexts["mortgage-monthly-payment"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mortgage-input-toggle"].exists)
        XCTAssertFalse(app.textFields["mortgage-amount"].exists)
        capture(app, "mortgage-trial-light")
        let compare = app.buttons["mortgage-result-action"]
        reveal(compare, app: app); compare.tap()
        XCTAssertTrue(app.buttons["mortgage-choose-principal"].waitForExistence(timeout: 5))
        app.buttons["mortgage-choose-principal"].tap()
        XCTAssertTrue(app.staticTexts["预计首月还款"].waitForExistence(timeout: 5))
        let inputs = app.buttons["mortgage-input-toggle"]
        reveal(inputs, app: app); inputs.tap()
        XCTAssertTrue(app.textFields["mortgage-amount"].waitForExistence(timeout: 5))
        capture(app, "mortgage-loan-settings")
    }
    func testPrepaymentUsesTrialAndBothStrategies() {
        let app = launch()
        app.buttons["mortgage-scene-prepayment"].tap()
        let source = app.buttons["mortgage-option-new"]
        reveal(source, app: app); source.tap()
        let payment = app.buttons["mortgage-strategy-payment"]
        reveal(payment, app: app); payment.tap()
        top(app)
        XCTAssertTrue(app.staticTexts["提前还款后月供"].waitForExistence(timeout: 5))
        capture(app, "mortgage-prepayment")
        let compare = app.buttons["mortgage-result-action"]
        reveal(compare, app: app); compare.tap()
        XCTAssertTrue(app.buttons["mortgage-choose-term"].waitForExistence(timeout: 5))
        capture(app, "mortgage-strategy-comparison")
        app.buttons["mortgage-choose-term"].tap()
        XCTAssertTrue(app.staticTexts["提前还款后月供"].waitForExistence(timeout: 5))
    }
    func testNativeDetailsAndChartTableInDarkMode() {
        let app = launch(dark: true)
        capture(app, "mortgage-trial-dark")
        let schedule = app.buttons["mortgage-schedule"]
        reveal(schedule, app: app); schedule.tap()
        XCTAssertTrue(app.navigationBars["还款计划明细"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第 1 年"].exists)
        app.buttons["mortgage-sheet-close"].tap()
        let table = app.buttons["mortgage-chart-data"]
        reveal(table, app: app); table.tap()
        XCTAssertTrue(app.navigationBars["剩余本金数据"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["还款起点"].exists)
        capture(app, "mortgage-balance-data-dark")
    }
    func testRestoredInvalidDraftStaysExpandedWhileBecomingValid() {
        var app = launch()
        let inputs = app.buttons["mortgage-input-toggle"]
        reveal(inputs, app: app); inputs.tap()
        let mode = app.buttons["mortgage-amount-mode"]
        if mode.label.contains("填贷款额") { mode.tap() }
        let amount = app.textFields["mortgage-amount"]
        reveal(amount, app: app); amount.tap()
        let count = (amount.value as? String ?? "").count
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        XCTAssertTrue(app.staticTexts["请填写有效贷款金额或房价、首付比例"].waitForExistence(timeout: 5))
        app.terminate()
        app = launch()
        let restored = app.textFields["mortgage-amount"]
        reveal(restored, app: app); restored.tap(); restored.typeText("2")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(restored.exists, "A successful calculation must not remove the active editor")
        XCTAssertEqual(restored.value as? String, "2")
        restored.typeText("10")
        XCTAssertEqual(restored.value as? String, "210")
    }
    func testAccessibilityTextKeepsScenesAndParametersReachable() {
        let app = launch(largeText: true)
        let inputs = app.buttons["mortgage-input-toggle"]
        reveal(inputs, app: app); inputs.tap()
        let amount = app.textFields["mortgage-amount"]
        reveal(amount, app: app)
        XCTAssertTrue(amount.isHittable)
        capture(app, "mortgage-accessibility-text")
        let current = app.buttons["mortgage-scene-current"]
        reveal(current, app: app); current.tap()
        XCTAssertTrue(app.buttons["mortgage-input-toggle"].waitForExistence(timeout: 5))
    }
    func testBottomNavigationStaysReachableAndChangesSceneAtTop() {
        let app = launch()
        let table = app.buttons["mortgage-chart-data"]
        reveal(table, app: app)
        XCTAssertTrue(app.buttons["mortgage-scene-trial"].isHittable)
        XCTAssertTrue(app.buttons["mortgage-scene-current"].isHittable)
        XCTAssertTrue(app.buttons["mortgage-scene-prepayment"].isHittable)
        app.buttons["mortgage-scene-prepayment"].tap()
        let payment = app.staticTexts["mortgage-monthly-payment"]
        XCTAssertTrue(payment.waitForExistence(timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in payment.isHittable }, object: nil)
        let visibility = XCTWaiter.wait(for: [visible], timeout: 5)
        capture(app, "mortgage-bottom-navigation-prepayment")
        XCTAssertEqual(visibility, .completed, "Switching the bottom navigation must bring the new scene to its summary")
        app.buttons["mortgage-scene-trial"].tap()
        XCTAssertTrue(app.buttons["mortgage-scene-trial"].isSelected)
        XCTAssertTrue(app.staticTexts["mortgage-monthly-payment"].isHittable)
        capture(app, "mortgage-bottom-navigation")
    }
}
