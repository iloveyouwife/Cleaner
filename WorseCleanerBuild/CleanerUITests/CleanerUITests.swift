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
        // Capture all three states using the OS search drawer; do not manually
        // animate the toolbar or replace the native search field.
        capture("search-drawer-at-top")
        app.swipeUp()
        capture("search-drawer-after-scroll")
        app.swipeDown()
        capture("search-drawer-after-pull-down")
    }

    func testSearchFocusKeepsNativeToolbarAndDismissesOnSwipe() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10),
                      "The search field should be visible.")
        capture("search-inactive-gray")
        let inactiveFrame = search.frame
        search.tap()
        capture("search-active-system-appearance")
        let activeFrame = search.frame
        XCTAssertLessThan(abs(activeFrame.minX - inactiveFrame.minX), 6,
                          "The leading edge must stay fixed when search opens.")
        XCTAssertLessThan(abs(activeFrame.minY - inactiveFrame.minY), 6,
                          "Search should not shift vertically on activation.")
        XCTAssertLessThan(abs(activeFrame.height - inactiveFrame.height), 6,
                          "Search should keep its original height.")
        XCTAssertLessThan(activeFrame.width, inactiveFrame.width - 12,
                          "The field must shrink from the trailing edge.")
        XCTAssertTrue(app.buttons["关闭搜索"].waitForExistence(timeout: 5),
                      "The animated cancel button must appear.")
        app.buttons["关闭搜索"].tap()
        capture("search-after-cancel")
        // SwiftUI can retain an accessibility element while its animated
        // zero-width container is hidden; verify that it is no longer tappable.
        let cancelHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"),
            object: app.buttons["关闭搜索"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cancelHidden], timeout: 3), .completed,
                       "Tapping cancel must close search without reopening it.")
        XCTAssertLessThan(abs(search.frame.width - inactiveFrame.width), 6,
                          "The search field must return to its inactive width.")
        search.tap()
        app.swipeDown()
        capture("search-after-downward-swipe")
        if search.isHittable {
            search.tap()
            app.swipeUp()
            capture("search-after-upward-swipe")
        }
    }

    func testSearchDismissesOnBackgroundTap() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let originalWidth = search.frame.width
        search.tap()
        XCTAssertLessThan(search.frame.width, originalWidth - 12)
        let cancel = app.buttons["关闭搜索"]
        XCTAssertTrue(cancel.isHittable)
        // Tap the noninteractive space within the summary card, above the keyboard.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.32)).tap()
        capture("search-after-background-tap")
        let cancelHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"),
            object: cancel
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cancelHidden], timeout: 3), .completed,
                       "Tapping outside search must close the cancel button.")
        XCTAssertLessThan(abs(search.frame.width - originalWidth), 6,
                          "Tapping outside search must restore the inactive width.")
    }

    func testSearchVerticalSpacingMatchesCompactDrawerLayout() {
        let app = launchPreview()
        let search = searchInput(in: app)
        let heading = app.staticTexts["有限清理模式"]
        let navigation = app.navigationBars.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(navigation.waitForExistence(timeout: 10))

        // Catch v72's excessive gaps above and below the search input.
        // Leave a little slack for system font and rendering differences.
        let topGap = search.frame.minY - navigation.frame.maxY
        let bottomGap = heading.frame.minY - search.frame.maxY
        XCTAssertGreaterThanOrEqual(topGap, -4, "Search overlaps navigation.")
        XCTAssertLessThan(topGap, 28, "Top List content margin is still pushing search too far below navigation.")
        XCTAssertGreaterThanOrEqual(bottomGap, 4, "Search overlaps heading.")
        XCTAssertLessThan(bottomGap, 30, "Excess space below search.")
        capture("search-v71-compact-spacing")

        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertLessThan(abs(search.frame.minY - (navigation.frame.maxY + topGap)), 6,
                          "Search must not move vertically when activated.")
    }

    func testContinuousSearchTypingPreservesKeyboardAndClearButton() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))

        // The old Section-header field could lose focus when filtering
        // changed the number of rows and flipped into an empty state.
        for character in ["Q", "Q", "Z"] {
            search.typeText(character)
            XCTAssertTrue(keyboard.waitForExistence(timeout: 3),
                          "Keyboard dismissed while user was still typing.")
            XCTAssertTrue(search.isHittable)
        }
        let clear = app.buttons["清除搜索文字"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3),
                      "Clearing the query should keep the keyboard open.")
        XCTAssertFalse(clear.exists)
        capture("search-multiple-keystrokes-keyboard-stable")
    }

    func testRepeatedSearchTapsKeepKeyboardOpen() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10),
                      "The keyboard must appear on first search activation.")
        let activeFrame = search.frame

        for _ in 0..<3 {
            search.tap()
            XCTAssertTrue(keyboard.isHittable,
                          "A repeated search tap must not dismiss the keyboard.")
            XCTAssertLessThan(abs(search.frame.width - activeFrame.width), 6,
                              "Repeated taps must not replay the search-opening transition.")
            XCTAssertTrue(app.buttons["关闭搜索"].isHittable,
                          "The search field must stay in the active state.")
        }
        capture("search-repeated-taps-keyboard-stable")
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
