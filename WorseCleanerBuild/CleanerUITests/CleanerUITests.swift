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
