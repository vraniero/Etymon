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

        // roots and meanings can be shown separately or together
        let picker = app.descendants(matching: .any)["layersPicker"]
        picker.buttons["Roots"].tap()
        XCTAssertTrue(app.staticTexts["pater"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["= open"].exists, "Roots view shows no meaning links")
        shot("8-roots-only")
        picker.buttons["Meanings"].tap()
        XCTAssertTrue(app.staticTexts["= open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["pater"].exists, "Meanings view shows no ancestors")
        shot("9-meanings-only")
        picker.buttons["Both"].tap()
        XCTAssertTrue(app.staticTexts["pater"].waitForExistence(timeout: 5))

        // the help screen explains the controls
        app.descendants(matching: .any)["help"].tap()
        XCTAssertTrue(app.navigationBars["How it works"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Type or paste words and press Connect; the network is shown as a graph."].exists)
        shot("7-help")
        app.navigationBars["How it works"].buttons["Done"].tap()

        let fullPaths = app.descendants(matching: .any)["fullPaths"]
        fullPaths.tap()
        sleep(1)
        shot("6-typed-full-paths")
    }

    func testMapJourney() {
        let app = XCUIApplication()
        // the argument shows the map without changing the remembered Tree/Map choice
        app.launchArguments = ["-source", "type", "-demo", "-networkStyle", "map"]
        app.launch()
        let follow = app.descendants(matching: .any)["journeyMenu"].firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 15))
        sleep(2)
        shot("13-map")

        // follow padre from Italy back to its Proto-Indo-European root
        follow.tap()
        app.buttons["padre"].firstMatch.tap()
        let card = app.buttons["journeyClose"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The word you saw"].exists)
        sleep(2)
        shot("14-journey-leaf")
        let forward = app.buttons["journeyForward"]
        forward.tap()
        XCTAssertTrue(app.staticTexts["patre"].waitForExistence(timeout: 5))
        forward.tap()
        XCTAssertTrue(app.staticTexts["pater"].waitForExistence(timeout: 5))
        sleep(2)
        shot("15-journey-latin")
        while forward.isEnabled { forward.tap() }
        XCTAssertTrue(app.staticTexts["Oldest known root"].waitForExistence(timeout: 5))
        sleep(2)
        shot("16-journey-root")
        app.buttons["journeyBack"].tap()
        XCTAssertFalse(app.staticTexts["Oldest known root"].exists)

        app.buttons["journeyClose"].tap()
        XCTAssertFalse(card.waitForExistence(timeout: 2))
        XCTAssertTrue(follow.exists)
    }

    func testExploreIn3D() {
        let app = XCUIApplication()
        app.launchArguments = ["-source", "type", "-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["pater"].waitForExistence(timeout: 15))

        app.descendants(matching: .any)["explore"].firstMatch.tap()
        let opened = app.buttons["closeExplore"].waitForExistence(timeout: 5)
        sleep(3)  // let the layout settle
        shot("10-explore-3d")
        XCTAssertTrue(opened, "Explore did not open")

        // jump to a word seen in the scene, then expand it
        app.buttons["jump-padre"].tap()
        XCTAssertTrue(app.staticTexts["exploreSelected"].waitForExistence(timeout: 5))
        sleep(1)
        shot("11-explore-selected")
        // padre comes from Old Italian patre, which comes from Latin pater
        app.buttons["jump-patre"].firstMatch.tap()
        XCTAssertTrue(app.buttons["jump-pater"].waitForExistence(timeout: 5))
        app.buttons["jump-pater"].firstMatch.tap()
        let expand = app.buttons["expandNode"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(app.buttons["jump-Pater"].waitForExistence(timeout: 10),
                      "expanding pater brings in its descendants (German Pater)")
        sleep(3)
        shot("12-explore-expanded")

        // the panel is a sheet: its lists scroll inside it, and its handle resizes it
        let handle = app.buttons["explorePanelHandle"]
        let list = app.scrollViews["explorePanelList"]
        XCTAssertTrue(handle.exists && list.exists)
        let peek = list.frame.height
        XCTAssertLessThan(peek, app.frame.height * 0.3, "the panel leaves most of the screen to the tree")
        let grip = handle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.05, thenDragTo: grip.withOffset(.init(dx: 0, dy: -300)))
        XCTAssertTrue(waitFor { list.frame.height > peek + 50 }, "dragging the handle up enlarges it")
        shot("13-explore-panel-expanded")
        let grip2 = handle.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        grip2.press(forDuration: 0.05, thenDragTo: grip2.withOffset(.init(dx: 0, dy: 600)))
        XCTAssertTrue(waitFor { !list.exists && !expand.exists }, "dragging it down collapses it")
        XCTAssertTrue(app.staticTexts["exploreSelected"].exists, "collapsed, the word stays visible")
        shot("14-explore-panel-collapsed")
        handle.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 3), "tapping the handle opens it again")

        app.buttons["closeExplore"].tap()
        XCTAssertTrue(app.staticTexts["pater"].waitForExistence(timeout: 5))
    }

    private func waitFor(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
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
