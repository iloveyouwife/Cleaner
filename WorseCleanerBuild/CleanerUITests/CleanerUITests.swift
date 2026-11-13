import XCTest

/// Native menu screenshots with populated simulator-only App rows.
/// These tests never invoke cache enumeration or deletion.
final class CleanerUITests: XCTestCase {
    private func launchPreview(selected: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            selected ? "-capturePopulatedSelection" : "-capturePopulatedHome"
        ]
        app.launch()
        let firstRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "微信")
        ).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15),
                      "The fixture App list should be visible before capturing menus.")
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMenu(_ label: String, in app: XCUIApplication) {
        let control = app.buttons.matching(
            NSPredicate(format: "label == %@", label)
        ).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10), "Missing menu: " + label)
        control.tap()
        sleep(1)
    }

    private func searchInput(in app: XCUIApplication) -> XCUIElement {
        let native = app.searchFields.firstMatch
        if native.exists { return native }
        return app.textFields["搜索 App"]
    }

    func testSelectionMenuTwoItems() {
        let app = launchPreview()
        openMenu("选择操作", in: app)
        capture("selection-menu-two-items")
    }

    func testSelectionMenuFourItems() {
        let app = launchPreview(selected: true)
        openMenu("选择操作", in: app)
        capture("selection-menu-four-items")
    }

    func testBulkSelectionLivesAboveList() {
        let app = launchPreview()
        let selectAll = app.buttons["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10),
                      "After scanning, the list heading should offer bulk selection.")
        selectAll.tap()
        let clearAll = app.buttons["取消全选"]
        XCTAssertTrue(clearAll.waitForExistence(timeout: 5),
                      "Selecting all should switch the same control to 取消全选.")
        XCTAssertTrue(app.staticTexts["已选择 7 项"].exists,
                      "The collapsed Bundle ID group must not be selected.")
        capture("bulk-select-selected")
        clearAll.tap()
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已选择 0 项"].exists,
                      "Toggling again should clear all selections.")
        capture("bulk-select-cleared")
    }

    func testSearchBulkUnselectPreservesHiddenAppSelection() {
        let app = launchPreview()
        let first = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "微信")
        ).firstMatch
        XCTAssertTrue(first.isHittable)
        first.tap()
        XCTAssertTrue(app.staticTexts["已选择 1 项"].waitForExistence(timeout: 5))

        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("QQ")
        // The bulk-selection button already existed before typing.
        // Wait for the debounced result refresh, otherwise the test might
        // select the original full list instead of the filtered QQ result.
        let removed = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "微信")
        ).firstMatch
        let filtered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: removed
        )
        XCTAssertEqual(XCTWaiter.wait(for: [filtered], timeout: 8), .completed)
        let selectAll = app.buttons["全选"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        XCTAssertTrue(app.staticTexts["已选择 2 项"].waitForExistence(timeout: 5))
        app.buttons["取消全选"].tap()
        XCTAssertTrue(app.staticTexts["已选择 1 项"].waitForExistence(timeout: 5),
                      "Canceling filtered selection must preserve the hidden selection.")
        capture("search-bulk-deselect-preserves-hidden")
    }

    func testExcludedRecordsRemainRestorableAfterDiscoveryIsCleared() {
        let app = launchPreview(selected: true)
        openMenu("选择操作", in: app)
        let exclude = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "排除选中的")).firstMatch
        XCTAssertTrue(exclude.waitForExistence(timeout: 5))
        exclude.tap()
        XCTAssertTrue(app.staticTexts["已选择 0 项"].waitForExistence(timeout: 5))
        // The unsigned fixture has no signed group. Refresh clears discovery,
        // while preserving the two explicit exclusion records, with no scan.
        app.buttons["刷新 App 列表"].tap()
        XCTAssertTrue(app.buttons["打开高级设置"].waitForExistence(timeout: 10))
        openMenu("选择操作", in: app)
        app.buttons["管理已排除 App（2）"].tap()
        XCTAssertTrue(app.navigationBars["管理已排除 App"].waitForExistence(timeout: 5))
        let restore = app.buttons["全部恢复"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        XCTAssertTrue(app.staticTexts["暂无已排除 App"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        openMenu("选择操作", in: app)
        XCTAssertTrue(app.buttons["管理已排除 App"].waitForExistence(timeout: 5))
    }

    func testSortMenu() {
        let app = launchPreview()
        openMenu("排序", in: app)
        capture("sort-menu")
    }

    func testMoreMenu() {
        let app = launchPreview()
        openMenu("更多选项", in: app)
        capture("more-menu")
    }

    func testLongNamesKeepCacheSizeAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["-captureLongRows"]
        app.launch()
        let longRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "MagnifierAngelWithAnUnusuallyLongDisplayName，缓存 1.2 GB")
        ).firstMatch
        // List rows may be lazily instantiated below the initial viewport.
        for _ in 0..<8 {
            if longRow.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(longRow.waitForExistence(timeout: 5),
                      "A long title must retain its accessible cache-size amount.")
        capture("long-names-and-amounts")
    }

    func testSearchDrawerScrollInteraction() {
        let app = launchPreview()
        // Capture the persistent search field before and after List scrolling.
        capture("search-drawer-at-top")
        app.swipeUp()
        capture("search-drawer-after-scroll")
        app.swipeDown()
        capture("search-drawer-after-pull-down")
    }

    func testSearchFocusKeepsNativeToolbarAndDismissesOnSwipe() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let inactiveFrame = search.frame
        capture("v71-search-inactive")
        search.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        let activeFrame = search.frame
        XCTAssertLessThan(abs(activeFrame.minX - inactiveFrame.minX), 6)
        XCTAssertLessThan(abs(activeFrame.minY - inactiveFrame.minY), 6)
        XCTAssertLessThan(abs(activeFrame.height - inactiveFrame.height), 6)
        XCTAssertLessThan(activeFrame.width, inactiveFrame.width - 12,
                          "Search should shrink smoothly from the trailing edge.")
        let close = app.buttons["关闭搜索"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        capture("v71-search-animated-expanded")
        close.tap()
        XCTAssertFalse(close.isHittable, "Round close must dismiss active search.")
        XCTAssertLessThan(abs(search.frame.width - inactiveFrame.width), 6)
        search.tap()
        app.swipeUp()
        capture("search-fixed-viewport-collapsed")
        XCTAssertFalse(search.isHittable,
                       "The search overlay must hide after the first upward scroll.")
        app.swipeDown()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable,
                      "The first return swipe must reveal the overlay again.")
        capture("search-fixed-viewport-first-return")
        // A full scroll cycle must always remain reversible, without a
        // second swipe or a search bar stuck over a deeply scrolled App list.
        app.swipeUp()
        capture("search-fixed-viewport-second-collapse")
        XCTAssertFalse(search.isHittable,
                       "Search must not stick at the top after repeated scrolls.")
        app.swipeDown()
        XCTAssertTrue(search.isHittable, "Second cycle must restore search.")
        capture("search-fixed-viewport-second-return")
    }

    func testSearchDismissesOnBackgroundTap() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let cancel = app.buttons["关闭搜索"]
        XCTAssertTrue(cancel.isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.36)).tap()
        XCTAssertFalse(cancel.isHittable, "Tapping the List must close search.")
        capture("v71-search-outside-tap-dismiss")
    }

    func testSearchVerticalSpacingMatchesCompactDrawerLayout() {
        let app = launchPreview()
        let search = searchInput(in: app)
        let heading = app.staticTexts["有限清理模式"]
        let nav = app.navigationBars.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(nav.waitForExistence(timeout: 10))
        XCTAssertTrue(search.isHittable)
        let topGap = search.frame.minY - nav.frame.maxY
        let bottomGap = heading.frame.minY - search.frame.maxY
        XCTAssertGreaterThanOrEqual(topGap, -4)
        XCTAssertLessThan(topGap, 50, "Search is too far below toolbar.")
        XCTAssertGreaterThanOrEqual(bottomGap, 0)
        XCTAssertLessThan(bottomGap, 60, "Excess gap between search and heading.")
        capture("v71-search-stable-layout")
    }

    func testContinuousSearchTypingPreservesKeyboardAndClearButton() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        for character in ["Q", "Q", "Z"] {
            search.typeText(character)
            Thread.sleep(forTimeInterval: 0.35)
            XCTAssertTrue(keyboard.isHittable,
                          "The keyboard must not jump as filtered result sets change.")
            XCTAssertTrue(search.isHittable)
            XCTAssertTrue(app.buttons["关闭搜索"].isHittable)
        }
        let clear = app.buttons["清除搜索文字"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertTrue(keyboard.isHittable,
                      "Clearing search to restore the full List must retain keyboard.")
        XCTAssertFalse(clear.exists)
        search.typeText("Q")
        XCTAssertTrue(keyboard.isHittable,
                      "Search must continue accepting input without retapping.")
        capture("search-results-change-with-stable-keyboard")
    }

    func testRepeatedSearchTapsKeepKeyboardOpen() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        let frame = search.frame
        for _ in 0..<3 {
            search.tap()
            XCTAssertTrue(keyboard.isHittable)
            XCTAssertLessThan(abs(search.frame.width - frame.width), 6)
            XCTAssertTrue(app.buttons["关闭搜索"].isHittable)
        }
        capture("search-repeated-taps-without-keyboard-bounce")
    }

    func testUnconfirmedAppGroupWarningOpensSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-captureUnconfirmedGroup"]
        app.launch()

        let warning = app.staticTexts["请确认 App Group"]
        XCTAssertTrue(warning.waitForExistence(timeout: 15),
                      "The unconfirmed App Group warning must be shown.")
        let open = app.buttons["打开高级设置"]
        XCTAssertTrue(open.waitForExistence(timeout: 10),
                      "Warning must expose an actionable settings button.")
        XCTAssertTrue(open.isHittable, "The warning action must be tappable.")
        XCTAssertFalse(app.buttons["刷新 App 列表"].isEnabled,
                       "Refresh must be disabled until the App Group is confirmed.")
        XCTAssertTrue(app.staticTexts["0 KB"].exists,
                      "Revoking permission must clear previously scanned cache results.")
        capture("unconfirmed-warning-before-tap")
        open.tap()
        XCTAssertTrue(app.navigationBars["高级设置"].waitForExistence(timeout: 10),
                      "Tapping the warning action must present advanced settings.")
        XCTAssertTrue(app.buttons["完成"].exists)
        let deepScan = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "深度发现 App 容器")
        ).firstMatch
        XCTAssertTrue(deepScan.exists)
        XCTAssertFalse(deepScan.isEnabled, "Deep discovery must require confirmation.")
        capture("unconfirmed-warning-settings-open")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["打开高级设置"].waitForExistence(timeout: 5),
                      "Closing settings should restore the warning action.")
    }

    func testAdvancedSettingsRowsAndDiagnostics() {
        let app = XCUIApplication()
        app.launchArguments = ["-captureAdvancedSettings"]
        app.launch()

        let access = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "缓存访问权限")
        ).firstMatch
        XCTAssertTrue(access.waitForExistence(timeout: 15), "Missing access status row")

        let discovery = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "深度发现 App 容器")
        ).firstMatch
        XCTAssertTrue(discovery.exists, "Missing discovery button")
        capture("advanced-settings-first-rows")

        app.swipeUp()
        let diagnostics = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "查看访问诊断日志")
        ).firstMatch
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5), "Missing diagnostics row")
        capture("advanced-settings-diagnostics")

        diagnostics.tap()
        let signatureGroups = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "签名声明的 App Group")
        ).firstMatch
        XCTAssertTrue(signatureGroups.waitForExistence(timeout: 5),
                      "Diagnostics group should expand and reveal its content")
        capture("advanced-settings-expanded")
    }

    func testExcludedAppsEmptyState() {
        let app = XCUIApplication()
        app.launchArguments = ["-captureExcludedApps"]
        app.launch()
        let emptyState = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "暂无已排除 App")
        ).firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 15),
                      "Expected system-style empty state")
        capture("excluded-empty-state")
    }
}
