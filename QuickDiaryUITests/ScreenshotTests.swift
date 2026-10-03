import UIKit
import XCTest

/// Walks through the app with demo data and saves a screenshot of each screen.
/// Screenshots go to the test results, and to $SCREENSHOT_DIR when it is set
/// (CI passes TEST_RUNNER_SCREENSHOT_DIR to xcodebuild).
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func shot(_ name: String) {
        let name = "\(isPad ? "ipad" : "iphone")-\(name)"
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty {
            let folder = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }

    private func element(_ app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "missing field \(field)")
        field.tap()
        dismissKeyboardTip()
        field.typeText(text)
    }

    /// The first keyboard use shows a "slide to type" tip with a Continue button.
    private func dismissKeyboardTip() {
        let app = XCUIApplication()
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 1) { continueButton.tap() }
    }

    /// Taps the visible back button. Several navigation bars can be in the tree
    /// (a sheet over the list), so find it by its title.
    /// Back to the notes list. On iPad the list stays on screen, so there is no back button.
    private func backToNotes(_ app: XCUIApplication) {
        if !isPad { goBack(app, to: "Notes") }
    }

    private func goBack(_ app: XCUIApplication, to title: String) {
        // The list's gear button is also labelled "Settings", so take the hittable one.
        let matches = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), "no back button to \(title)")
        let button = matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
        button.tap()
    }

    func test1_CreateVault() {
        let app = launch(["-demoFresh"])
        XCTAssertTrue(app.secureTextFields["password"].waitForExistence(timeout: 15))
        shot("01-create-password")

        type("correct-horse", into: app.secureTextFields["password"])
        type("correct-horse", into: app.secureTextFields["confirm"])
        app.buttons["create"].tap()

        XCTAssertTrue(app.buttons["savedRecoveryKey"].waitForExistence(timeout: 30))
        shot("02-recovery-key")
        app.buttons["savedRecoveryKey"].tap()

        XCTAssertTrue(app.buttons["newNote"].waitForExistence(timeout: 10))
        shot("03-no-notes")
    }

    func test2_Tour() {
        let app = launch(["-demo"])
        let password = app.secureTextFields["unlockPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        shot("04-locked")

        // A wrong password shows an error and keeps the app locked.
        type("not-it", into: password)
        app.buttons["unlock"].tap()
        XCTAssertTrue(app.staticTexts["unlockError"].waitForExistence(timeout: 15))
        shot("05-wrong-password")

        type(LaunchOptions.demoPassword, into: password)
        app.buttons["unlock"].tap()
        let firstNote = element(app, labelContaining: "Morning run")
        XCTAssertTrue(firstNote.waitForExistence(timeout: 15))
        shot("06-notes")

        firstNote.tap()
        XCTAssertTrue(app.textViews["editor"].waitForExistence(timeout: 10))
        shot("07-editor")

        app.buttons["Preview"].tap()
        XCTAssertTrue(app.otherElements["preview"].waitForExistence(timeout: 5)
                      || app.scrollViews["preview"].waitForExistence(timeout: 5))
        shot("08-preview")
        backToNotes(app)

        // New note: typed, autosaved, back in the list.
        XCTAssertTrue(app.buttons["newNote"].waitForExistence(timeout: 10))
        app.buttons["newNote"].tap()
        let editor = app.textViews["editor"]
        type("# Typed by the UI test\n\nHello from **CI**.\n- [ ] check the screenshot", into: editor)
        XCTAssertTrue(element(app, labelContaining: "Saved, encrypted").waitForExistence(timeout: 10))
        shot("09-new-note")
        backToNotes(app)
        XCTAssertTrue(element(app, labelContaining: "Typed by the UI test").waitForExistence(timeout: 10))
        shot("10-notes-after-new")

        // Delete goes to Recently Deleted, not away for good.
        let weekend = element(app, labelContaining: "Weekend plan")
        XCTAssertTrue(weekend.waitForExistence(timeout: 5))
        weekend.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let deletedRow = element(app, labelContaining: "Recently Deleted")
        XCTAssertTrue(deletedRow.waitForExistence(timeout: 10))
        deletedRow.tap()
        XCTAssertTrue(element(app, labelContaining: "Weekend plan").waitForExistence(timeout: 10))
        shot("11-recently-deleted")
        backToNotes(app)

        // Settings: change the password, then show the recovery key with the new one.
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["changePassword"].waitForExistence(timeout: 10))
        shot("12-settings")

        app.buttons["help"].tap()
        XCTAssertTrue(element(app, labelContaining: "Recovery key").waitForExistence(timeout: 10))
        shot("13-help")
        goBack(app, to: "Settings")

        app.buttons["changePassword"].tap()
        type(LaunchOptions.demoPassword, into: app.secureTextFields["currentPassword"])
        type("better-pass", into: app.secureTextFields["newPassword"])
        type("better-pass", into: app.secureTextFields["confirmPassword"])
        app.buttons["applyPasswordChange"].tap()
        XCTAssertTrue(element(app, labelContaining: "Password changed").waitForExistence(timeout: 15))
        shot("14-password-changed")
        goBack(app, to: "Settings")

        app.buttons["recoveryKey"].tap()
        type("better-pass", into: app.secureTextFields["revealPassword"])
        app.buttons["reveal"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recoveryKeyText"].waitForExistence(timeout: 15))
        shot("15-recovery-key")
    }

    func test3_DarkAndLargeText() {
        let app = launch(["-demo", "-appearance", "dark",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let password = app.secureTextFields["unlockPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        shot("20-dark-large-locked")
        type(LaunchOptions.demoPassword, into: password)
        app.buttons["unlock"].tap()
        let firstNote = element(app, labelContaining: "Morning run")
        XCTAssertTrue(firstNote.waitForExistence(timeout: 15))
        shot("21-dark-large-notes")
        firstNote.tap()
        app.buttons["Preview"].tap()
        shot("22-dark-large-preview")
    }
}

/// The demo password, duplicated here because UI tests can't import the app module.
enum LaunchOptions {
    static let demoPassword = "demo1234"
}
