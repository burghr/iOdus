import XCTest
@testable import iOdus

@MainActor
final class SettingsMenuTests: XCTestCase {
    private func model() -> AppModel {
        let model = AppModel()
        model.startDemo()
        model.stack = [.home, .settings]
        model.resetSettings()
        return model
    }

    func testEachRowIsInExactlyOneCategory() {
        let rows = SettingsCategory.allCases.flatMap(\.rows)
        XCTAssertEqual(Set(rows), Set(SettingsRow.allCases))
        XCTAssertEqual(rows.count, SettingsRow.allCases.count, "No row in two categories")
        for category in SettingsCategory.allCases {
            XCTAssertLessThanOrEqual(category.rows.count, 4, "\(category) must fit in the window")
        }
    }

    func testUpAndDownChooseACategoryWithoutAFocusedRow() {
        let model = model()
        XCTAssertEqual(model.settingsFocus, .categories)
        XCTAssertNil(model.focusedSettingsRow)
        model.move(.down)
        XCTAssertEqual(model.settingsCategory, SettingsCategory.games.rawValue)
        XCTAssertEqual(model.settingsRows, [.installFolder, .rescan])
        model.move(.up); model.move(.up)
        XCTAssertEqual(model.settingsCategory, 0, "The list stops at the top")
        for _ in 0..<10 { model.move(.down) }
        XCTAssertEqual(model.settingsCategory, SettingsCategory.allCases.count - 1, "The list stops at the bottom")
    }

    func testAOrRightGoesIntoTheRowsAndBGoesBackToTheList() {
        let model = model()
        model.move(.down)                       // Games
        model.confirm()                         // A on the category
        XCTAssertEqual(model.settingsFocus, .rows)
        XCTAssertEqual(model.focusedSettingsRow, .installFolder)
        model.move(.down)
        XCTAssertEqual(model.focusedSettingsRow, .rescan)
        model.move(.down)
        XCTAssertEqual(model.focusedSettingsRow, .rescan, "The rows stop at the last row")

        model.back()
        XCTAssertEqual(model.settingsFocus, .categories)
        XCTAssertEqual(model.screen, .settings, "B in the rows does not close Settings")

        model.move(.right)
        XCTAssertEqual(model.focusedSettingsRow, .installFolder)
        model.move(.left)
        XCTAssertEqual(model.settingsFocus, .categories)

        model.back()
        XCTAssertEqual(model.screen, .home, "B on the list closes Settings")
    }

    func testAToggleRowWorksInsideItsCategory() {
        let model = model()
        let before = AppSettings.startFullScreen
        defer { AppSettings.startFullScreen = before }
        model.tapSettingsCategory(SettingsCategory.display.rawValue)
        XCTAssertEqual(model.settingsFocus, .categories, "A click on a category only shows its rows")
        model.tapSettings(0)
        XCTAssertEqual(model.focusedSettingsRow, .fullScreen)
        XCTAssertNotEqual(AppSettings.startFullScreen, before)
    }

    func testTheGuidePageLeavesOnlyFromTheCategoryList() {
        let model = model()
        let depth = model.stack.count
        XCTAssertTrue(model.guidePageAtRoot(depth: depth))
        model.move(.right)
        XCTAssertFalse(model.guidePageAtRoot(depth: depth), "B must first go back to the categories")
    }

    func testAnUpdateNotificationOpensSettingsNotGitHub() {
        let model = model()
        model.stack = [.home]
        // An old notification still has the link to the release page.
        model.notifications = [AppNotification(date: Date(), kind: .update, title: "iOdus 9.9.9 is available",
                                               detail: "d", action: .openURL("https://github.com/burghr/iOdus/releases"))]
        model.openNotification(0)
        XCTAssertEqual(model.screen, .settings)
        XCTAssertEqual(model.settingsCategory, SettingsCategory.updates.rawValue)
        XCTAssertEqual(model.focusedSettingsRow, .appUpdate)
    }

    func testTheUpdatesCategoryHasTheReleaseNotesRow() {
        XCTAssertEqual(SettingsCategory.updates.rows, [.appUpdate, .releaseNotes, .updates, .prereleases])
        let model = model()
        XCTAssertTrue(model.releasePageURL.hasPrefix("https://github.com/burghr/iOdus/releases"))
    }
}
