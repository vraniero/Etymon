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

    func testLanguagesInSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-api", "http://localhost:8000", "-memoryStore", "-packs"]
        app.launch()

        XCTAssertTrue(app.buttons["homeSettings"].waitForExistence(timeout: 5))
        app.buttons["homeSettings"].tap()
        let languages = app.buttons["languages"]
        XCTAssertTrue(languages.waitForExistence(timeout: 5))
        languages.tap()
        XCTAssertTrue(app.staticTexts["Core"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Italian"].exists)
        attach(app, "languages")
    }

    /// The bottom of Settings says which version and build this is ("1.0 (3)").
    func testVersionInSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-api", "http://localhost:8000", "-memoryStore"]
        app.launch()

        XCTAssertTrue(app.buttons["homeSettings"].waitForExistence(timeout: 5))
        app.buttons["homeSettings"].tap()
        let version = app.descendants(matching: .any)["appVersion"]
        for _ in 0..<6 where !version.isHittable { app.swipeUp() }
        XCTAssertTrue(version.exists)
        let shown = "\(version.label) \(version.value as? String ?? "")"
        XCTAssertNotNil(shown.range(of: #"\d+(\.\d+)+ \(\d+\)"#, options: .regularExpression),
                        "no version like 1.0 (3) in Settings: \(shown)")
        attach(app, "version")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
