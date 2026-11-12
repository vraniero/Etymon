import XCTest

/// The home screen: every mode in a menu, into a mode and back.
final class HomeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testHomeOpensModesAndComesBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-api", "http://localhost:8000", "-memoryStore"]
        app.launch()

        for mode in ["Photo", "Type", "Talk"] {
            XCTAssertTrue(app.buttons["home-\(mode)"].waitForExistence(timeout: 5), mode)
        }
        XCTAssertTrue(app.buttons["homeLibrary"].exists)
        attach(app, "home")

        // into Type: nothing typed yet, so Home goes straight back
        app.buttons["home-Type"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect"].isEnabled, "nothing to connect yet")
        app.buttons["home"].tap()
        XCTAssertTrue(app.buttons["home-Type"].waitForExistence(timeout: 5))

        // with a scene, Home asks first
        app.buttons["home-Type"].tap()
        let example = app.buttons["example-Family"]
        XCTAssertTrue(example.waitForExistence(timeout: 5))
        example.tap()
        let words = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'shared roots'")).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 15))
        app.buttons["home"].tap()
        let leave = app.buttons["Leave without saving"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        leave.tap()
        XCTAssertTrue(app.buttons["home-Photo"].waitForExistence(timeout: 5))

        // My network from home
        app.buttons["homeLibrary"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        attach(app, "library from home")
    }

    func testTypeKeyboardGoesAway() {
        let app = XCUIApplication()
        app.launchArguments = ["-api", "http://localhost:8000", "-memoryStore", "-source", "type"]
        app.launch()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let done = app.buttons["hideKeyboard"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        attach(app, "typing")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
