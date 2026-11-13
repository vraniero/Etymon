import XCTest

/// Root Chain against the app: a move of yours, then the app's. Needs the backend
/// (`ETYMON_API`, default localhost:8000).
final class ChainUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testPlayAgainstTheApp() {
        let app = XCUIApplication()
        let server = ProcessInfo.processInfo.environment["ETYMON_API"] ?? "http://localhost:8000"
        app.launchArguments = ["-api", server, "-memoryStore", "-chainStart", "father"]
        app.launch()

        let card = app.buttons["homeGames"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let chain = app.buttons["game-chain"]
        XCTAssertTrue(chain.waitForExistence(timeout: 5))
        attach(app, "games")
        chain.tap()
        XCTAssertTrue(app.buttons["chainStart"].waitForExistence(timeout: 5))
        attach(app, "chain-setup")
        app.buttons["chainStart"].tap()

        let field = app.textFields["chainWord"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["father"].exists)
        field.tap()
        field.typeText("padre")
        app.buttons["chainPlay"].tap()
        XCTAssertTrue(app.staticTexts["padre"].waitForExistence(timeout: 15), "the move is linked")

        // the app answers, and it's your turn again
        let yourTurn = NSPredicate(format: "label BEGINSWITH 'You, a word linked to'")
        let prompt = app.staticTexts.containing(yourTurn).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        XCTAssertFalse(prompt.label.contains("padre"), "Etymon has played a word after padre")
        attach(app, "chain-after-app-move")

        // a word with no link to the last one is a miss
        field.tap()
        field.typeText("qwzxv")
        app.buttons["chainPlay"].tap()
        XCTAssertTrue(app.staticTexts["chainMessage"].waitForExistence(timeout: 15))
        attach(app, "chain-unknown-word")
    }

    /// Each of the other games makes a puzzle and takes an answer.
    func testOtherGames() {
        let app = XCUIApplication()
        let server = ProcessInfo.processInfo.environment["ETYMON_API"] ?? "http://localhost:8000"
        app.launchArguments = ["-api", server, "-memoryStore", "-game", "impostor"]
        app.launch()

        // Impostor: pick one, the answer shows
        let first = app.buttons["impostorWord0"]
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        attach(app, "impostor")
        first.tap()
        XCTAssertTrue(app.buttons["impostorNext"].waitForExistence(timeout: 5))
        attach(app, "impostor-answer")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Cousin Hunt: a root, a word from it
        app.buttons["game-hunt"].tap()
        app.buttons["huntStart"].tap()
        let go = app.buttons["huntGo"]
        XCTAssertTrue(go.waitForExistence(timeout: 30))
        attach(app, "hunt-root")
        go.tap()
        let field = app.textFields["huntWord"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("qwzxv\n")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'know'"))
            .firstMatch.waitForExistence(timeout: 15))
        attach(app, "hunt-playing")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Birthplace: tap the map, guess, the journey shows
        app.buttons["game-birthplace"].tap()
        XCTAssertTrue(app.staticTexts["birthWord"].waitForExistence(timeout: 30))
        app.maps.firstMatch.tap()
        // the map takes a tap only once it can't be a double tap (zoom)
        let guess = app.buttons["birthGuess"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: guess)
        waitForExpectations(timeout: 5)
        guess.tap()
        XCTAssertTrue(app.buttons["Next word"].waitForExistence(timeout: 5)
                      || app.buttons["See score"].exists)
        attach(app, "birthplace")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Scavenger: an ancestor; a typed word is checked
        app.buttons["game-scavenger"].tap()
        let word = app.textFields["scavengerWord"]
        XCTAssertTrue(word.waitForExistence(timeout: 30))
        word.tap()
        word.typeText("table\n")
        XCTAssertTrue(app.staticTexts["scavengerStatus"].waitForExistence(timeout: 15))
        attach(app, "scavenger")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
