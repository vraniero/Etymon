import XCTest

/// Drives the app like a user: reads a photo of a pharmacy sign and checks the network
/// drawn over it, opens a connection and a word, then the typed-words graph. Needs the
/// backend running at localhost:8000. Screenshots are attached to the test result, and
/// also written to $ETYMON_SHOTS if set (pass it as TEST_RUNNER_ETYMON_SHOTS to xcodebuild).
final class EtymonUITests: XCTestCase {
    let sign = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("sign.png").path

    override func setUp() {
        continueAfterFailure = false
    }

    func testNetworkOverPhoto() {
        let app = XCUIApplication()
        app.launchArguments = ["-source", "photo", "-photo", sign]
        app.launch()

        // shared roots float over the words: FARMACIA + Pharmacy -> pharmacia,
        // notte + night -> *nókʷts; same meaning: Aperta = Open
        let pharmacia = app.staticTexts["pharmacia"]
        XCTAssertTrue(pharmacia.waitForExistence(timeout: 30), "overlay did not appear")
        XCTAssertTrue(app.staticTexts["*nókʷts"].exists, "notte ↔ night should meet at PIE *nókʷts")
        XCTAssertTrue(app.staticTexts["= open"].exists, "Aperta and Open should be linked by meaning")
        shot("1-overlay-on-photo")

        // the overlay sits on the words in the picture: outlines inside the photo, in
        // reading order (FARMACIA headline above notte, notte above night)
        let photo = app.images["pickedPhoto"].frame
        let farmacia = app.descendants(matching: .any)["word-farmacia"].frame
        let notte = app.descendants(matching: .any)["word-notte"].frame
        let night = app.descendants(matching: .any)["word-night"].frame
        for word in [farmacia, notte, night] {
            XCTAssertTrue(photo.contains(CGPoint(x: word.midX, y: word.midY)),
                          "word outline \(word) is outside the photo \(photo)")
        }
        XCTAssertLessThan(farmacia.midY, notte.midY)
        XCTAssertLessThan(notte.midY, night.midY)

        // tap the ancestor bubble: both chains and the deeper line
        pharmacia.tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 5))
        shot("2-connection-detail")
        dismissSheet(app)

        // tap a word on the picture: its own lineage
        app.descendants(matching: .any)["word-notte"].tap()
        XCTAssertTrue(app.staticTexts["nox"].waitForExistence(timeout: 10))
        shot("3-word-detail")
        dismissSheet(app)

        // the same network as a graph
        app.descendants(matching: .any)["showGraph"].tap()
        XCTAssertTrue(app.navigationBars["Network"].waitForExistence(timeout: 5))
        shot("4-graph-sheet")
    }

    func testTypedWords() {
        let app = XCUIApplication()
        app.launchArguments = ["-source", "type", "-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["pater"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["nox"].exists)
        XCTAssertTrue(app.staticTexts["= open"].exists)
        shot("5-typed-graph")

        let fullPaths = app.descendants(matching: .any)["fullPaths"]
        fullPaths.tap()
        sleep(1)
        shot("6-typed-full-paths")
    }

    private func dismissSheet(_ app: XCUIApplication) {
        // tap the dimmed area above the half-height sheet
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        sleep(1)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["ETYMON_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("\(name).png"))
        }
    }
}
