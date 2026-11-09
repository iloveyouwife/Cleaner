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
}
