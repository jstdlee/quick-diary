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
        // Text added from Shortcuts while locked becomes a note at unlock.
        let fromShortcuts = element(app, labelContaining: "From Shortcuts")
        XCTAssertTrue(fromShortcuts.waitForExistence(timeout: 15))
        let firstNote = element(app, labelContaining: "Morning run")
        XCTAssertTrue(firstNote.waitForExistence(timeout: 5))
        shot("06-notes")

        firstNote.tap()
        XCTAssertTrue(app.textViews["editor"].waitForExistence(timeout: 10))
        // The note's photo shows in the strip above the capture bar.
        XCTAssertTrue(app.descendants(matching: .any)["photoStrip"].waitForExistence(timeout: 5))
        shot("07-editor")

        // AI summary (demo engine): shown first, inserted only on Insert.
        app.buttons["aiMenu"].tap()
        app.buttons["Summarize note"].tap()
        XCTAssertTrue(app.staticTexts["aiResult"].waitForExistence(timeout: 10))
        shot("07b-ai-summary")
        app.buttons["aiInsert"].tap()
        XCTAssertTrue(wait(for: app.textViews["editor"], toContain: "### Summary"))

        app.buttons["Preview"].tap()
        // The encrypted photo decrypts and shows in the preview.
        XCTAssertTrue(app.images["Sunrise on the run"].waitForExistence(timeout: 10))
        shot("08-preview-with-photo")
        backToNotes(app)

        // New note with the capture bar: a quick entry and the weather.
        XCTAssertTrue(app.buttons["newNote"].waitForExistence(timeout: 10))
        app.buttons["newNote"].tap()
        let editor = app.textViews["editor"]
        type("# Typed by the UI test\n\nHello from **CI**.", into: editor)
        app.buttons["quick-Mood"].tap()
        app.buttons["🙂 Good"].firstMatch.tap()
        app.buttons["quick-Weather"].tap()
        XCTAssertTrue(wait(for: editor, toContain: "Mood: 🙂 Good"))
        XCTAssertTrue(wait(for: editor, toContain: "Weather: 18°C"))

        // Today: pick a photo, add the facts.
        app.buttons["quick-Today"].tap()
        XCTAssertTrue(element(app, labelContaining: "Pay the electricity bill").waitForExistence(timeout: 10))
        // The sheet opens at half height; pull it up so the photo grid loads.
        let photo = app.buttons["todayPhoto"].firstMatch
        if !photo.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        shot("09a-today")
        app.buttons["todayAdd"].tap()
        XCTAssertTrue(wait(for: editor, toContain: "## Today", timeout: 10))
        XCTAssertTrue(wait(for: editor, toContain: "- [x] Pay the electricity bill"))

        // Today again: an AI summary of the day.
        app.buttons["quick-Today"].tap()
        XCTAssertTrue(app.buttons["todaySummarize"].waitForExistence(timeout: 10))
        app.buttons["todaySummarize"].tap()
        XCTAssertTrue(app.staticTexts["aiResult"].waitForExistence(timeout: 10))
        shot("09b-day-summary")
        app.buttons["aiInsert"].tap()
        XCTAssertTrue(wait(for: editor, toContain: "productive day", timeout: 10))
        XCTAssertTrue(element(app, labelContaining: "Saved, encrypted").waitForExistence(timeout: 10))
        shot("09-new-note-capture-bar")
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

        // Settings
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["changePassword"].waitForExistence(timeout: 10))
        shot("12-settings")

        open(app, "quickEntries")
        XCTAssertTrue(element(app, labelContaining: "Breakfast").waitForExistence(timeout: 10))
        shot("14-quick-entries")
        goBack(app, to: "Settings")

        open(app, "attachments")
        XCTAssertTrue(element(app, labelContaining: "Used in 1 note").waitForExistence(timeout: 10))
        shot("13-attachments")
        goBack(app, to: "Settings")

        open(app, "aiSettings")
        XCTAssertTrue(app.descendants(matching: .any)["aiProvider"].waitForExistence(timeout: 10))
        shot("13b-ai-settings")
        goBack(app, to: "Settings")

        open(app, "backup")
        XCTAssertTrue(app.buttons["backupNow"].waitForExistence(timeout: 10))
        app.buttons["backupNow"].tap()
        XCTAssertTrue(element(app, labelContaining: "Backed up").waitForExistence(timeout: 20))
        shot("13c-backup")
        goBack(app, to: "Settings")

        open(app, "help")
        XCTAssertTrue(element(app, labelContaining: "Recovery key").waitForExistence(timeout: 10))
        shot("15-help")
        goBack(app, to: "Settings")

        open(app, "privacy")
        XCTAssertTrue(element(app, labelContaining: "No analytics").waitForExistence(timeout: 10))
        shot("16-privacy")
        goBack(app, to: "Settings")

        // Reopen Settings to start at the top again.
        app.buttons["Done"].tap()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["changePassword"].waitForExistence(timeout: 10))

        open(app, "changePassword")
        type(LaunchOptions.demoPassword, into: app.secureTextFields["currentPassword"])
        type("better-pass", into: app.secureTextFields["newPassword"])
        type("better-pass", into: app.secureTextFields["confirmPassword"])
        app.buttons["applyPasswordChange"].tap()
        XCTAssertTrue(element(app, labelContaining: "Password changed").waitForExistence(timeout: 15))
        shot("17-password-changed")
        goBack(app, to: "Settings")

        open(app, "recoveryKey")
        type("better-pass", into: app.secureTextFields["revealPassword"])
        app.buttons["reveal"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recoveryKeyText"].waitForExistence(timeout: 15))
        shot("18-recovery-key")
    }

    /// A text view's content is its value, not its label.
    private func wait(for textView: XCUIElement, toContain text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: textView)], timeout: timeout) == .completed
    }

    /// Scrolls the settings form down until the row is on screen, then opens it.
    /// (Only down: a swipe down at the top would close the sheet.)
    private func open(_ app: XCUIApplication, _ identifier: String) {
        let row = app.buttons[identifier]
        var tries = 0
        while !(row.exists && row.isHittable) && tries < 6 {
            app.swipeUp()
            tries += 1
        }
        row.tap()
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
