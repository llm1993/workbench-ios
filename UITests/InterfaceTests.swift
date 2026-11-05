import XCTest

final class InterfaceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ module: String? = nil, dark: Bool = false, screen: String = "list", autoRead: Bool = false, largeText: Bool = false, readerListStyle: String? = nil, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", screen, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-appearance", dark ? "dark" : "light"]
        if let module { app.launchArguments += ["--preview-module", module] }
        if autoRead { app.launchArguments.append("--enable-auto-read") }
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if let readerListStyle { app.launchArguments += ["--reader-list-style", readerListStyle] }
        app.launchArguments += extraArguments
        app.launch()
        return app
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func tapMenuLabel(_ menu: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(menu.exists)
        XCTAssertTrue(menu.isEnabled)
        XCTAssertGreaterThan(menu.frame.width, 0)
        XCTAssertGreaterThan(menu.frame.height, 0)
        XCTAssertTrue(app.frame.contains(menu.frame), "Menu label must be inside the visible app")
        // SwiftUI Menu's AX activation point can be {-1,-1} on this simulator even for a
        // visible enabled label. Use its real touch location, then assert the resulting actions.
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    func testHome() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["日常应用"].waitForExistence(timeout: 15))
        capture(app, name: "home-light")
    }
    func testHomeLayoutShowsEachAppName() {
        let app = launch()
        let settings = app.buttons["账户与设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        app.buttons["门厅应用排序与显隐"].tap()
        for (key, name) in [("youshu", "有数"), ("weidu", "未读"), ("clip", "剪贴板"), ("stock", "股讯"), ("mortgage", "房贷")] {
            let toggle = app.switches["layout-" + key].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.label, name)
        }
        capture(app, name: "home-layout-app-names")
    }
    private func check(_ module: String, ready: String, dark: Bool = false) {
        let app = launch(module, dark: dark)
        let content = module == "weidu" ? app.buttons["entry-preview-0"] : app.staticTexts[ready]
        XCTAssertTrue(content.waitForExistence(timeout: 15))
        capture(app, name: module + (dark ? "-dark" : "-light"))
        XCTAssertFalse(app.navigationBars["工作台"].staticTexts["工作台"].isHittable)
        if module == "weidu" { XCTAssertFalse(app.tabBars.firstMatch.isHittable) }
        if module == "weidu" {
            app.buttons["文章操作"].tap()
            app.buttons["返回应用首页"].tap()
        } else { app.buttons["module-exit"].tap() }
        let home = app.staticTexts["日常应用"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in home.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed)
    }
    func testClipboard() { check("clip", ready: "最近内容") }
    func testReader() { check("weidu", ready: "把注意力还给真正喜欢的事") }
    func testAssets() { check("youshu", ready: "物品净值") }
    func testStock() { check("stock", ready: "判断表现") }
    func testMortgage() { check("mortgage", ready: "贷款") }
    func testClipboardDark() { check("clip", ready: "最近内容", dark: true) }
    func testReaderDark() { check("weidu", ready: "把注意力还给真正喜欢的事", dark: true) }

    private func revealAsset(_ element: XCUIElement, in app: XCUIApplication, detail: Bool = false) {
        let scroll = app.scrollViews[detail ? "assets-detail-scroll" : "assets-scroll"].firstMatch
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable)
    }
    private func tapCategory(_ id: String, in app: XCUIApplication) {
        let categories = app.scrollViews["assets-categories"]
        let chip = app.buttons["assets-category-" + id]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            let frame = chip.frame, viewport = categories.frame
            if frame.width > 0, frame.height > 0, frame.minX >= viewport.minX, frame.maxX <= viewport.maxX {
                chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return
            }
            if frame.midX > viewport.midX { categories.swipeLeft() } else { categories.swipeRight() }
        }
        XCTFail("Category must be visible before receiving a physical touch")
    }
    private func waitForDismissal(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }
    private func openAsset(_ id: Int, in app: XCUIApplication) {
        app.buttons["assets-tab-inventory"].tap()
        let row = app.buttons["assets-row-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); revealAsset(row, in: app); row.tap()
        XCTAssertTrue(app.navigationBars["物品详情"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["assets-detail-record"].waitForExistence(timeout: 10))
    }
    func testAssetsBottomNavigationAndQuickRecordRemainVisibleAfterScrolling() {
        let app = launch("youshu")
        XCTAssertTrue(app.staticTexts["assets-net-value"].waitForExistence(timeout: 10))
        app.scrollViews["assets-scroll"].swipeUp(velocity: .slow)
        for name in ["overview", "inventory", "wishes", "review"] { XCTAssertTrue(app.buttons["assets-tab-" + name].isHittable) }
        let add = app.buttons["assets-quick-add"]
        XCTAssertTrue(add.isHittable); add.tap()
        for name in ["newAsset", "cost", "income", "valuation", "wish"] { XCTAssertTrue(app.buttons["assets-action-" + name].waitForExistence(timeout: 5)) }
        capture(app, name: "assets-visible-quick-actions")
    }
    func testAssetsInventoryUsesDynamicCategoriesAndSearchResults() {
        let app = launch("youshu")
        XCTAssertTrue(app.buttons["assets-tab-inventory"].waitForExistence(timeout: 10)); app.buttons["assets-tab-inventory"].tap()
        let custom = app.buttons["assets-category-42"]
        XCTAssertTrue(custom.waitForExistence(timeout: 10))
        XCTAssertEqual(custom.label, "阅读装备"); tapCategory("42", in: app)
        XCTAssertTrue(app.buttons["assets-row-7"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["assets-row-1"].exists)
        tapCategory("all", in: app)
        let search = app.textFields["assets-search"]
        search.tap(); search.typeText("MacBook")
        XCTAssertTrue(app.buttons["assets-row-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 件物品 · 全部状态"].waitForExistence(timeout: 10))
        waitForDismissal(app.buttons["assets-row-7"])
        XCTAssertEqual(search.value as? String, "MacBook")
        XCTAssertTrue(app.buttons["assets-quick-add"].isHittable)
        capture(app, name: "assets-search-and-categories")
    }
    func testAssetsDetailRecordsCostAndKeepsFooterVisibleWithJournal() {
        let app = launch("youshu")
        XCTAssertTrue(app.buttons["assets-tab-inventory"].waitForExistence(timeout: 10)); openAsset(1, in: app)
        XCTAssertTrue(app.buttons["assets-detail-valuation"].isHittable)
        app.buttons["assets-detail-record"].tap(); app.buttons["assets-action-cost"].tap()
        let amount = app.textFields["form-field-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.tap(); amount.typeText("25.00")
        let note = app.descendants(matching: .any)["form-field-note"].firstMatch
        note.tap(); note.typeText("Interface cost fixture")
        app.buttons["native-form-save"].tap()
        waitForDismissal(app.navigationBars["记一笔成本"])
        let journal = app.segmentedControls["assets-detail-tabs"].buttons["台账"]
        revealAsset(journal, in: app, detail: true); journal.tap()
        let entry = app.staticTexts["Interface cost fixture"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); revealAsset(entry, in: app, detail: true)
        XCTAssertTrue(app.buttons["assets-detail-record"].isHittable)
        XCTAssertTrue(app.buttons["assets-detail-valuation"].isHittable)
        capture(app, name: "assets-detail-journal-and-footer")
    }
    func testAssetsUnknownValuationIsUpdatedFromOverview() {
        let app = launch("youshu")
        let pending = app.buttons["assets-pending-6"]
        XCTAssertTrue(pending.waitForExistence(timeout: 10)); revealAsset(pending, in: app); pending.tap()
        let value = app.textFields["form-field-current_value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5)); value.tap(); value.typeText("500")
        app.buttons["native-form-save"].tap()
        waitForDismissal(app.navigationBars["更新估值"])
        waitForDismissal(app.buttons["assets-pending-6"])
        app.buttons["assets-tab-inventory"].tap()
        let search = app.textFields["assets-search"]; search.tap(); search.typeText("AirPods")
        let row = app.buttons["assets-row-6"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.staticTexts["assets-detail-net-cost"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["待补估值"].exists)
        capture(app, name: "assets-updated-valuation")
    }
    func testAssetsNewItemUsesCollapsedOptionalFieldsAndOpensSavedDetail() {
        let app = launch("youshu")
        XCTAssertTrue(app.buttons["assets-quick-add"].waitForExistence(timeout: 10)); app.buttons["assets-quick-add"].tap()
        app.buttons["assets-action-newAsset"].tap()
        let name = app.descendants(matching: .any)["form-field-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Interface new item")
        let price = app.textFields["form-field-purchase_price"]; price.tap(); price.typeText("123.45")
        XCTAssertFalse(app.textFields["form-field-quantity"].exists)
        app.descendants(matching: .any)["form-additional-fields"].firstMatch.tap()
        XCTAssertTrue(app.textFields["form-field-quantity"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["form-field-quantity"].value as? String, "1")
        app.buttons["native-form-save"].tap()
        XCTAssertTrue(app.navigationBars["物品详情"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Interface new item"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["assets-detail-valuation"].isHittable)
        capture(app, name: "assets-new-item-detail")
    }
    func testAssetsRemindersReviewAndStatisticsAreReachable() {
        let app = launch("youshu")
        let reminders = app.buttons["assets-reminders"]
        XCTAssertTrue(reminders.waitForExistence(timeout: 10)); reminders.tap()
        XCTAssertTrue(app.navigationBars["提醒与待办"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assets-new-reminder"].exists)
        XCTAssertTrue(app.buttons["assets-complete-reminder-1"].waitForExistence(timeout: 10))
        capture(app, name: "assets-reminders")
        app.navigationBars["提醒与待办"].buttons["关闭"].tap()
        app.buttons["assets-tab-review"].tap()
        XCTAssertTrue(app.staticTexts["成本提醒"].waitForExistence(timeout: 10))
        let statistics = app.buttons["assets-menu"]
        tapMenuLabel(statistics, in: app); app.buttons["完整统计"].tap()
        XCTAssertTrue(app.navigationBars["完整统计"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["净值与投入"].waitForExistence(timeout: 10))
        capture(app, name: "assets-full-statistics")
    }
    func testAssetsFailedSavePreservesInputAndAllowsRetry() {
        let app = launch("youshu", extraArguments: ["--assets-save-failure"])
        XCTAssertTrue(app.buttons["assets-quick-add"].waitForExistence(timeout: 10)); app.buttons["assets-quick-add"].tap()
        app.buttons["assets-action-cost"].tap()
        let item = app.buttons["assets-pick-1"]
        XCTAssertTrue(item.waitForExistence(timeout: 10)); item.tap()
        let amount = app.textFields["form-field-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.tap(); amount.typeText("88.00")
        app.buttons["native-form-save"].tap()
        XCTAssertTrue(app.staticTexts["form-failure"].waitForExistence(timeout: 10))
        XCTAssertEqual(amount.value as? String, "88.00")
        capture(app, name: "assets-save-error-retains-input")
        app.buttons["native-form-save"].tap()
        waitForDismissal(app.navigationBars["记一笔成本"])
    }
    func testAssetsDarkLargeTextKeepsAmountsPrivateAndDetailActionsReachable() {
        let app = launch("youshu", dark: true, largeText: true)
        let privacy = app.buttons["assets-privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10)); privacy.tap()
        XCTAssertEqual(app.staticTexts["assets-net-value"].label, "••••")
        XCTAssertTrue(app.buttons["assets-quick-add"].isHittable)
        openAsset(1, in: app)
        let netCost = app.staticTexts["assets-detail-net-cost"]
        revealAsset(netCost, in: app, detail: true)
        XCTAssertTrue(app.buttons["assets-detail-record"].isHittable)
        XCTAssertTrue(app.buttons["assets-detail-valuation"].isHittable)
        XCTAssertEqual(netCost.label, "••••")
        capture(app, name: "assets-dark-large-private")
    }

    private func revealClipboard(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["clip-timeline"].firstMatch
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            scroll.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable)
    }
    func testClipboardFileRelayIsVisibleAfterScrollingAndOpensDirectly() {
        let app = launch("clip")
        let relay = app.buttons["clip-file-relay"]
        XCTAssertTrue(relay.waitForExistence(timeout: 10))
        app.scrollViews["clip-timeline"].swipeUp(velocity: .slow)
        XCTAssertTrue(relay.isHittable)
        XCTAssertTrue(app.buttons["clip-send"].isHittable)
        capture(app, name: "clip-persistent-bottom-actions")
        relay.tap()
        XCTAssertTrue(app.navigationBars["文件传输"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["选择文件"].waitForExistence(timeout: 5))
        capture(app, name: "clip-file-relay-direct")
    }
    func testFileTransferStartsWithLocalDevicesAndCloudRequiresExplicitSelection() {
        let app = launch("clip")
        app.buttons["clip-file-relay"].tap()
        XCTAssertTrue(app.navigationBars["文件传输"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["附近设备"].exists)
        XCTAssertTrue(app.switches["lan-enabled"].exists)
        XCTAssertTrue(app.staticTexts["lan-empty-records"].exists)
        XCTAssertFalse(app.buttons["lan-select-files"].isEnabled)
        XCTAssertFalse(app.staticTexts["中转中的文件"].exists)
        app.segmentedControls["transfer-channel"].buttons["云端中转"].tap()
        XCTAssertTrue(app.staticTexts["中转中的文件"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["选择文件"].exists)
        capture(app, name: "file-transfer-explicit-cloud")
    }
    func testFileTransferLocalHelpDoesNotStartAnUpload() {
        let app = launch("clip")
        app.buttons["clip-file-relay"].tap()
        let enabled = app.switches["lan-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 8))
        if enabled.value as? String == "0" { enabled.tap() }
        XCTAssertTrue(app.buttons["lan-help"].waitForExistence(timeout: 5))
        app.buttons["lan-help"].tap()
        XCTAssertTrue(app.alerts["没有发现电脑？"].waitForExistence(timeout: 5))
        app.alerts.buttons["知道了"].tap()
        XCTAssertFalse(app.buttons["lan-select-files"].isEnabled)
        capture(app, name: "file-transfer-local-permission-help")
    }
    func testFileTransferSupportsDarkLargeTextAndKeepsCloudChoiceExplicit() {
        let app = launch("clip", dark: true, largeText: true)
        app.buttons["clip-file-relay"].tap()
        XCTAssertTrue(app.segmentedControls["transfer-channel"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["附近设备"].exists)
        XCTAssertTrue(app.switches["lan-enabled"].exists)
        capture(app, name: "file-transfer-local-large-dark")
    }
    func testClipboardMenuOnlyExposesClipboardEncryptionSettings() {
        let app = launch("clip")
        let menu = app.buttons["clip-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        capture(app, name: "clip-before-encryption-menu")
        tapMenuLabel(menu, in: app)
        app.buttons["剪贴板加密设置"].tap()
        XCTAssertTrue(app.navigationBars["剪贴板加密设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["新加密口令（至少 8 位）"].exists)
        XCTAssertFalse(app.buttons["重新登录 / 切换账号"].exists)
        XCTAssertFalse(app.buttons["退出登录"].exists)
        XCTAssertFalse(app.buttons["清空全部剪贴板历史"].exists)
        capture(app, name: "clip-encryption-only")
    }
    func testClipboardDirectCopyDoesNotOpenDetailsAndDetailsUseASheet() {
        let app = launch("clip")
        let copy = app.buttons["clip-copy-40"]
        XCTAssertTrue(app.buttons["clip-send"].waitForExistence(timeout: 10))
        revealClipboard(copy, in: app); copy.tap()
        let notice = app.staticTexts["clip-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        XCTAssertEqual(notice.label, "已复制到 iPhone")
        XCTAssertFalse(app.navigationBars["文字详情"].exists)
        app.buttons["clip-record-40"].tap()
        XCTAssertTrue(app.navigationBars["文字详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["clip-detail-text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["clip-detail-copy"].isEnabled)
        capture(app, name: "clip-text-detail-sheet")
    }
    func testClipboardLocalFavoritesAndImageFilter() {
        let app = launch("clip")
        XCTAssertTrue(app.buttons["clip-send"].waitForExistence(timeout: 10))
        let star = app.buttons["clip-favorite-40"]
        revealClipboard(star, in: app); star.tap()
        app.scrollViews["clip-timeline"].swipeDown(velocity: .slow)
        let favorites = app.buttons["clip-scope-favorites"]
        XCTAssertTrue(favorites.isHittable); favorites.tap()
        XCTAssertTrue(app.buttons["clip-record-40"].exists)
        XCTAssertFalse(app.buttons["clip-record-39"].exists)
        app.buttons["clip-kind-image"].tap()
        XCTAssertTrue(app.staticTexts["暂无匹配的本机收藏"].waitForExistence(timeout: 5))
        app.buttons["clip-scope-all"].tap()
        let image = app.buttons["clip-record-39"]
        revealClipboard(image, in: app); image.tap()
        XCTAssertTrue(app.navigationBars["图片详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["完整图片"].waitForExistence(timeout: 5))
        capture(app, name: "clip-image-detail-sheet")
    }
    func testClipboardBulkDeleteCanBeUndoneBeforeSubmission() {
        let app = launch("clip")
        let selection = app.buttons["clip-selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 10)); selection.tap()
        let row = app.buttons["clip-record-40"]
        revealClipboard(row, in: app); row.tap()
        app.buttons["clip-bulk-delete"].tap()
        app.buttons["删除 1 条内容"].tap()
        let undo = app.buttons["clip-undo-delete"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["clip-record-40"].exists)
        undo.tap()
        XCTAssertTrue(app.buttons["clip-record-40"].waitForExistence(timeout: 5))
        capture(app, name: "clip-delete-restored")
    }
    func testClipboardComposeUsesRealFixtureEncryptionAndRefresh() {
        let app = launch("clip")
        let send = app.buttons["clip-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10)); send.tap()
        let editor = app.textViews["clip-compose-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("发送流程回归测试")
        app.buttons["clip-compose-submit"].tap()
        XCTAssertTrue(app.buttons["clip-record-41"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["发送内容"].exists)
        capture(app, name: "clip-compose-sent")
    }
    func testClipboardLargeTextKeepsFileRelayAndSendReachable() {
        let app = launch("clip", dark: true, largeText: true)
        XCTAssertTrue(app.buttons["clip-file-relay"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["clip-file-relay"].isHittable)
        XCTAssertTrue(app.buttons["clip-send"].isHittable)
        capture(app, name: "clip-accessibility-large-dark")
    }

    func testReaderFirstRowFollowsHeaderOnLaunchSearchAndReturnToTop() {
        for style in ["plain", "card"] {
            let app = launch("weidu", screen: "features-regression", readerListStyle: style)
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 15))
            let header = app.descendants(matching: .any).matching(identifier: "article-list-header").firstMatch
            let first = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry-")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 5)); XCTAssertTrue(first.waitForExistence(timeout: 5))
            let firstID = first.identifier
            func assertTop(_ label: String) {
                let row = app.buttons[firstID]
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                // Read each actual frame once. Repeated synchronous AX queries can exhaust a
                // predicate's timeout while the keyboard is active and mix different snapshots.
                let rowFrame = row.frame, headerFrame = header.frame
                XCTAssertGreaterThan(rowFrame.height, 0)
                XCTAssertGreaterThan(headerFrame.height, 0)
                let gap = rowFrame.minY - headerFrame.maxY
                let message = label + " / " + style + " / gap=\(gap), header=\(headerFrame), row=\(rowFrame)"
                print("Reader alignment: " + message)
                if style == "plain" { XCTAssertEqual(gap, 0, accuracy: 3, message) }
                else {
                    XCTAssertGreaterThanOrEqual(gap, 0, message)
                    XCTAssertLessThanOrEqual(gap, 60, message)
                }
            }
            assertTop("initial layout")
            app.buttons["搜索"].tap()
            capture(app, name: "weidu-expanded-search-top-" + style)
            assertTop("expanded search")
            let searchResult = app.buttons[firstID]
            XCTAssertTrue(searchResult.isEnabled)
            searchResult.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let back = app.buttons["返回文章列表"]
            XCTAssertTrue(back.waitForExistence(timeout: 5), "A real touch must open the visible search result")
            capture(app, name: "weidu-search-result-open-" + style)
            let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 15), .completed)
            back.tap()
            assertTop("return from search result")
            app.buttons["取消"].tap()
            assertTop("collapsed search")
            list.swipeUp(velocity: .slow); list.swipeDown(velocity: .slow)
            let tab = app.buttons["tab-articles"]
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tab.isHittable }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
            tab.doubleTap()
            assertTop("double-tap return to top")
            capture(app, name: "weidu-first-row-top-" + style)
            app.terminate()
        }
    }

    func testReaderShowsFulltextLoadingUntilNewDocumentIsDisplayed() {
        let app = launch("weidu", screen: "reader-loading-regression")
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let first = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry-")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        let actions = app.buttons["reader-article-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        capture(app, name: "weidu-before-reader-actions")
        tapMenuLabel(actions, in: app)
        app.buttons["抓正文"].tap()
        let status = app.staticTexts["reader-loading-message"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertEqual(status.label, "正在抓取全文…")
        capture(app, name: "weidu-fulltext-loading")
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["过渡测试正文，抓取完成后平滑显示。"].waitForExistence(timeout: 8))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !status.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        tapMenuLabel(actions, in: app); app.buttons["看订阅源原文"].tap()
        XCTAssertTrue(web.staticTexts["订阅源原文第1篇，原始内容仍然保留。"].waitForExistence(timeout: 8))
        capture(app, name: "weidu-source-transition-finished")
    }

    func testReaderListStylePersistsAfterRelaunch() {
        let app = launch("weidu")
        XCTAssertTrue(app.buttons["tab-settings"].waitForExistence(timeout: 15))
        func styleButton(_ title: String) -> XCUIElement {
            let button = app.buttons["article-list-style-" + (title == "平铺" ? "plain" : "card")].firstMatch
            let scroll = app.scrollViews["settings-scroll"].firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 5))
            for _ in 0..<16 {
                // XCTest considers partly covered controls hittable. Keep the entire
                // option above the floating tabs before asking it to tap the center.
                let top = scroll.frame.minY + 12
                let bottom = app.buttons["tab-settings"].frame.minY - 16
                let frame = button.exists ? button.frame : .zero
                if button.exists && button.isHittable && frame.height > 0 && frame.minY >= top && frame.maxY <= bottom {
                    return button
                }
                let distance: CGFloat = frame.height > 0 && frame.minY < top ? 150 : -150
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: scroll.frame.midX, dy: (top + bottom) / 2))
                let end = start.withOffset(CGVector(dx: 0, dy: distance))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("列表样式选项未完整滚动到页签上方")
            return button
        }
        app.buttons["tab-settings"].tap()
        styleButton("平铺").tap()
        capture(app, name: "weidu-list-style-settings")
        let plain = app.buttons["article-list-style-plain"].firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in plain.exists && plain.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.buttons["tab-articles"].tap()
        let article = app.buttons["entry-preview-0"]
        XCTAssertTrue(article.waitForExistence(timeout: 5))
        XCTAssertTrue(article.isHittable)
        capture(app, name: "weidu-list-plain")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["tab-settings"].waitForExistence(timeout: 15))
        app.buttons["tab-settings"].tap()
        XCTAssertTrue(styleButton("平铺").isSelected)
        styleButton("卡片").tap()
    }

    func testReaderTabBarFollowsScrollAndReturnsForNavigation() {
        let app = launch("weidu", screen: "scroll-regression")
        let feeds = app.buttons["tab-feeds"]
        XCTAssertTrue(feeds.waitForExistence(timeout: 15))
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let viewportHeight = list.frame.height
        list.swipeUp(velocity: .slow)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !feeds.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertEqual(list.frame.height, viewportHeight, accuracy: 1)
        capture(app, name: "weidu-tab-bar-hidden")
        list.swipeDown(velocity: .slow)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in feeds.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        capture(app, name: "weidu-tab-bar-visible")
        feeds.tap()
        app.swipeUp(velocity: .slow)
        XCTAssertTrue(app.buttons["tab-settings"].isHittable)
        app.buttons["tab-articles"].tap()
        XCTAssertTrue(app.buttons["tab-feeds"].isHittable)
    }

    func testReaderScrollReadMarksPassedRowsAfterScrollingSettles() {
        let app = launch("weidu", screen: "features-regression", autoRead: true)
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let rows = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry-"))
        let first = rows.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let identifier = first.identifier
        XCTAssertEqual(first.value as? String, "未读")
        let viewportHeight = list.frame.height
        list.swipeUp(velocity: .slow)
        XCTAssertEqual(list.frame.height, viewportHeight, accuracy: 1)
        list.swipeDown(velocity: .slow)
        let passedRow = app.buttons[identifier]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            passedRow.exists && passedRow.value as? String == "已读"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["tab-feeds"].isHittable)
        capture(app, name: "weidu-scroll-read-settled")
    }

    func testReaderArticlesAreSeparateReusableCellsAndSupportSwipeActions() {
        let app = launch("weidu")
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let first = list.cells.containing(.button, identifier: "entry-preview-0").firstMatch
        let second = list.cells.containing(.button, identifier: "entry-preview-1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.height, list.frame.height / 2, "A day group must not become one giant non-reusable cell")
        XCTAssertNotEqual(first.frame.minY, second.frame.minY)
        first.swipeLeft()
        let read = app.buttons["entry-read-preview-0"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab-feeds"].isHittable, "A horizontal row swipe must not hide navigation")
        capture(app, name: "weidu-independent-row-swipe")
        read.tap()
        XCTAssertEqual(app.buttons["entry-preview-0"].value as? String, "已读")
    }

    func testReaderDoubleTapReturnsToTopAndHidesReadWithoutDroppingUnreadRows() {
        let app = launch("weidu", screen: "features-regression")
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let rows = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry-"))
        let firstID = rows.element(boundBy: 0).identifier
        let secondID = rows.element(boundBy: 1).identifier
        list.cells.containing(.button, identifier: firstID).firstMatch.swipeLeft()
        app.buttons["entry-read-" + String(firstID.dropFirst(6))].tap()
        XCTAssertEqual(app.buttons[firstID].value as? String, "已读")
        list.swipeUp(velocity: .slow)
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53)))
        XCTAssertTrue(app.buttons["tab-articles"].isHittable)
        app.buttons["tab-articles"].doubleTap()
        let top = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.buttons[secondID].isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [top], timeout: 5), .completed)
        XCTAssertFalse(app.buttons[firstID].exists)
        XCTAssertEqual(app.buttons[secondID].value as? String, "未读")
        capture(app, name: "weidu-double-tap-top-hide-read")
    }

    func testReaderForegroundKeepsTheVisibleArticlePosition() {
        let app = launch("weidu", screen: "features-regression")
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        list.swipeUp(velocity: .slow)
        let rows = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry-"))
        guard let anchor = rows.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.minY > list.frame.minY + 100 }) else {
            XCTFail("No visible article to anchor"); return
        }
        let id = anchor.identifier, before = anchor.frame.minY
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons[id].frame.minY, before, accuracy: 2)
        capture(app, name: "weidu-foreground-position")
    }

    func testReaderSettingsFooterIsAboveTabsAndDoubleTapReturnsToTop() {
        let app = launch("weidu")
        XCTAssertTrue(app.buttons["tab-settings"].waitForExistence(timeout: 15))
        app.buttons["tab-settings"].tap()
        let footer = app.staticTexts["reader-settings-footer"]
        for _ in 0..<12 {
            if footer.isHittable { break }
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(footer.isHittable)
        XCTAssertLessThan(footer.frame.maxY, app.buttons["tab-settings"].frame.minY)
        capture(app, name: "weidu-settings-bottom-clearance")
        app.buttons["tab-settings"].doubleTap()
        let theme = app.buttons["主题，跟随系统"].firstMatch
        let top = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in theme.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [top], timeout: 5), .completed)
        app.buttons["tab-feeds"].tap()
        let lastFeed = app.buttons["feed-more-tech"]
        XCTAssertTrue(lastFeed.waitForExistence(timeout: 5))
        XCTAssertLessThan(lastFeed.frame.maxY, app.buttons["tab-feeds"].frame.minY)
    }

    func testReaderPrefetchLoadsBeforeTheEndWithAutoReadOff() {
        let app = launch("weidu", screen: "pagination-regression")
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let progress = app.descendants(matching: .any).matching(identifier: "article-list").firstMatch
        func loadedCount() -> Int {
            Int((progress.value as? String ?? "").split(separator: " ").first.map(String.init) ?? "") ?? 0
        }
        let initial = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in progress.value as? String == "40 篇已加载" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [initial], timeout: 5), .completed)
        for _ in 0..<12 {
            if loadedCount() >= 80 { break }
            list.swipeUp(velocity: .slow)
        }
        // The requirement is that the next page is ready before its first row
        // appears. A fast subsequent prefetch must not make this assertion fail.
        let prefetched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in loadedCount() >= 80 }, object: nil)
        let result = XCTWaiter.wait(for: [prefetched], timeout: 5)
        capture(app, name: "weidu-prefetch-before-end")
        XCTAssertEqual(result, .completed, "实际加载状态：\(String(describing: progress.value))")
        XCTAssertFalse(app.staticTexts["功能测试第41篇"].isHittable, "Next page is available before its rows enter the viewport")
    }
}
