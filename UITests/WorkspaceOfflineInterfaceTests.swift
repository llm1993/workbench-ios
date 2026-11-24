import XCTest

final class WorkspaceOfflineInterfaceTests: XCTestCase {
    func testSignedOutHomeOpensLocalTools() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "list", "--preview-signed-out",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let salary = app.buttons["home-app-salary"]
        XCTAssertTrue(salary.waitForExistence(timeout: 10))
        salary.tap()
        XCTAssertTrue(app.buttons["salary-scene-calc"].waitForExistence(timeout: 10))
        app.buttons["module-exit"].tap()

        let mortgage = app.buttons["home-app-mortgage"]
        XCTAssertTrue(mortgage.waitForExistence(timeout: 5))
        mortgage.tap()
        XCTAssertTrue(app.staticTexts["mortgage-monthly-payment"].waitForExistence(timeout: 10))
        app.buttons["mortgage-plans"].tap()
        XCTAssertTrue(app.buttons["新建草稿"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["打开云端方案"].exists)
        app.buttons["新建草稿"].tap()
        app.buttons["取消"].tap()
        app.buttons["module-exit"].tap()

        let reader = app.buttons["home-app-localReader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        reader.tap()
        XCTAssertTrue(app.buttons["tab-articles"].waitForExistence(timeout: 10))
    }

    func testUnlockedAccountOpensLANWithoutEnteringClipboardSync() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "list", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let lan = app.buttons["home-app-lan"]
        XCTAssertTrue(lan.waitForExistence(timeout: 10))
        lan.tap()
        XCTAssertTrue(app.buttons["lan-select-files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["局域网直传"].exists)
    }
}
