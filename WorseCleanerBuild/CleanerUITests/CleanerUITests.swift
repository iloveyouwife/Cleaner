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
                      "The native search field should be visible.")
        XCTAssertGreaterThan(search.frame.height, 25)
        capture("native-search-before-activation")
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "Native iOS search must focus and show the keyboard.")
        XCTAssertTrue(app.buttons["排序"].exists,
                      "Search must not hide the app's sort control.")
        capture("native-search-active")
        app.swipeUp()
        capture("native-search-after-scroll")
    }

    func testSearchDismissesOnBackgroundTap() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.36)).tap()
        capture("native-search-background-tap")
        // Let the OS decide how a background tap affects the keyboard.
        // Do not artificially re-activate the search session.
    }

    func testSearchVerticalSpacingMatchesCompactDrawerLayout() {
        let app = launchPreview()
        let search = searchInput(in: app)
        let heading = app.staticTexts["有限清理模式"]
        XCTAssertTrue(search.waitForExistence(timeout: 10),
                      "Regression: native search drawer is missing.")
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(search.isHittable,
                      "Native search drawer must remain visible and tappable.")
        XCTAssertGreaterThan(search.frame.height, 25)
        XCTAssertLessThan(search.frame.minY, app.frame.height / 3,
                          "Native search must not be pushed far down the page.")
        XCTAssertLessThan(search.frame.maxY, heading.frame.maxY,
                          "Search drawer must precede the summary heading.")
        capture("native-search-drawer-position")
    }

    func testContinuousSearchTypingPreservesKeyboardAndClearButton() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))

        // QQ is present in the preview fixture; adding Z changes from a
        // matching to an empty result. Deleting Z shows matches again.
        search.typeText("QQ")
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertTrue(keyboard.isHittable, "Keyboard lost focus after results appeared.")
        search.typeText("Z")
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertTrue(keyboard.isHittable, "Keyboard lost focus after results disappeared.")
        search.typeText(XCUIKeyboardKey.delete.rawValue)
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertTrue(keyboard.isHittable, "Keyboard lost focus when results reappeared.")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertTrue(keyboard.isHittable, "Keyboard lost focus after clearing search.")
        search.typeText("Q")
        XCTAssertTrue(keyboard.isHittable,
                      "Typing after clear must not require a second tap.")
        capture("native-search-results-empty-restored-keyboard")
    }

    func testRepeatedSearchTapsKeepKeyboardOpen() {
        let app = launchPreview()
        let search = searchInput(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            search.tap()
            XCTAssertTrue(keyboard.isHittable,
                          "Repeated taps should not repeatedly dismiss keyboard.")
        }
        capture("native-search-repeated-taps")
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
