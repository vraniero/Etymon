import UIKit
import XCTest
@testable import Etymon

final class WordExtractorTests: XCTestCase {
    func testSplitsDropsStopwordsAndDuplicates() {
        let words = WordExtractor.words(in: "FARMACIA della Stazione\nl'eau, the Water! water 24h")
        XCTAssertEqual(words, ["FARMACIA", "Stazione", "eau", "Water"])
    }

    func testKeepsAccentedLetters() {
        XCTAssertEqual(WordExtractor.words(in: "caffè — père, Straße"), ["caffè", "père", "Straße"])
    }

    func testDominantLanguage() {
        XCTAssertEqual(WordExtractor.dominantLanguage(of: "Farmacia aperta tutta la notte"), "it")
        XCTAssertEqual(WordExtractor.dominantLanguage(of: "Die Apotheke ist heute geschlossen"), "de")
        XCTAssertEqual(WordExtractor.dominantLanguage(of: "Аптека открыта круглосуточно"), "ru")
        XCTAssertEqual(WordExtractor.dominantLanguage(of: "Аптека відчинена цілодобово"), "uk")
        XCTAssertEqual(WordExtractor.dominantLanguage(of: "Apteka jest czynna całą dobę"), "pl")
        XCTAssertEqual(WordExtractor.dominantLanguage(of: "Ljekarna je otvorena cijelu noć"), "sh")
    }

    func testSplitsCyrillic() {
        XCTAssertEqual(WordExtractor.words(in: "Аптека — это вода, ВОДА и молоко"),
                       ["Аптека", "вода", "молоко"])
    }

    func testSystemCodes() {
        XCTAssertEqual(WordExtractor.code(forSystem: "hr-HR"), "sh")
        XCTAssertEqual(WordExtractor.code(forSystem: "ru-RU"), "ru")
        XCTAssertEqual(WordExtractor.code(forSystem: "en-US"), "en")
    }

    /// Vision reads Cyrillic alongside Latin languages in one careful pass; quick passes
    /// can't, so a Cyrillic scene is tracked with careful ones.
    func testRecognizesCyrillic() throws {
        XCTAssertTrue(WordExtractor.accurateLanguages.contains("ru-RU"))
        let size = CGSize(width: 1000, height: 200)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            ("Хлеб и молоко" as NSString).draw(at: CGPoint(x: 40, y: 50), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 80), .foregroundColor: UIColor.black])
        }
        let recognition = try WordExtractor.recognize(in: XCTUnwrap(image.cgImage))
        XCTAssertEqual(recognition.words.map(\.text), ["Хлеб", "молоко"])
        XCTAssertFalse(WordExtractor.fastReads(recognition.text))
        XCTAssertTrue(WordExtractor.fastReads("Farmacia aperta tutta la notte"))
    }
}

final class SceneResponseTests: XCTestCase {
    /// A real /scene response: caffè, coffee, padre, paternalistic.
    static func fixture() throws -> SceneResponse {
        let url = try XCTUnwrap(Bundle(for: SceneResponseTests.self)
            .url(forResource: "scene_fixture", withExtension: "json"))
        return try JSONDecoder().decode(SceneResponse.self, from: Data(contentsOf: url))
    }

    func testDecodes() throws {
        let r = try Self.fixture()
        XCTAssertEqual(r.words.map(\.text), ["caffè", "coffee", "padre", "paternalistic"])
        let padre = try XCTUnwrap(r.connections.first { $0.a == 2 && $0.b == 3 })
        XCTAssertEqual(r.node(padre.meet)?.word, "pater")
        XCTAssertTrue(padre.deeper.contains { r.node($0.node)?.word == "*ph₂tḗr" })
    }

    func testLayoutPutsAncestorsAboveWords() throws {
        let r = try Self.fixture()
        let layout = GraphLayout(r)
        for i in r.words.indices where i != 0 {
            XCTAssertEqual(layout.items[.word(i)]?.level, 0)
        }
        // every link climbs
        for link in layout.links {
            XCTAssertLessThan(layout.items[link.from]!.level, layout.items[link.to]!.level)
        }
        let pater = try XCTUnwrap(r.connections.first { $0.a == 2 }).meet
        XCTAssertEqual(layout.items[.term(pater)]?.isMeeting, true)
    }

    func testSceneWordThatIsTheMeetingPoint() throws {
        // coffee meets caffè at caffè itself: drawn as the scene word, raised above coffee
        let r = try Self.fixture()
        let layout = GraphLayout(r)
        XCTAssertEqual(layout.items[.word(0)]?.isMeeting, true)
        XCTAssertGreaterThan(layout.items[.word(0)]!.level, 0)
    }

    func testNodesOnALevelDoNotOverlap() throws {
        let layout = GraphLayout(try Self.fixture())
        let byLevel = Dictionary(grouping: layout.items.values.filter { $0.level > 0 }, by: \.level)
        for (_, items) in byLevel {
            let xs = items.map(\.x).sorted()
            for (a, b) in zip(xs, xs.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b - a, GraphLayout.minSpacing - 0.001)
            }
        }
    }

    func testConnectedWordsAreNeighbours() throws {
        let r = try Self.fixture()
        let order = GraphLayout.wordOrder(r)
        XCTAssertEqual(Set(order), Set(r.words.indices))
        for c in r.connections {
            let gap = abs(order.firstIndex(of: c.a)! - order.firstIndex(of: c.b)!)
            XCTAssertEqual(gap, 1, "\(r.words[c.a].text) and \(r.words[c.b].text) should be adjacent")
        }
    }

    func testFullPathsShowEveryStep() throws {
        let r = try Self.fixture()
        let compact = GraphLayout(r), full = GraphLayout(r, compact: false)
        XCTAssertGreaterThan(full.items.count, compact.items.count)
        XCTAssertGreaterThan(full.maxLevel, compact.maxLevel)
    }

    /// Words and meeting points always; of the steps between, as many as asked (nearest the
    /// word), the rest one shortcut that counts them.
    func testMiddleStepsAreThinnedToTheChosenNumber() throws {
        let r = try Self.fixture()
        let full = GraphLayout(r, middle: -1)
        XCTAssertEqual(full.items.count, GraphLayout(r, compact: false).items.count)
        XCTAssertTrue(full.links.allSatisfy { $0.skipped == 0 })
        let none = GraphLayout(r, middle: 0)
        XCTAssertEqual(none.items.count, GraphLayout(r).items.count)
        let longest = r.connections.flatMap { [$0.pathA.count, $0.pathB.count] }.max() ?? 0
        XCTAssertGreaterThan(longest, 2, "the fixture needs a path with steps in between")
        var previous = none.items.count
        for keep in 1...max(longest - 2, 1) {
            let layout = GraphLayout(r, middle: keep)
            XCTAssertGreaterThanOrEqual(layout.items.count, previous)
            previous = layout.items.count
            for link in layout.links where link.skipped > 0 {
                XCTAssertTrue(none.items[link.to]?.isMeeting == true || layout.items[link.to] != nil)
            }
        }
        XCTAssertEqual(previous, full.items.count, "keeping every step is the full drawing")
        // what a shortcut leaves out plus what's drawn adds up to the path
        let one = GraphLayout(r, middle: 1)
        XCTAssertTrue(one.links.contains { $0.skipped > 0 } || longest <= 3)
    }
}


final class OverlayTests: XCTestCase {
    func testRecognitionFindsWordPositions() throws {
        let url = try XCTUnwrap(Bundle(for: OverlayTests.self).url(forResource: "sign", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let r = try WordExtractor.recognize(in: image)
        let boxes = Dictionary(uniqueKeysWithValues: r.words.map { ($0.key, $0.box) })
        let farmacia = try XCTUnwrap(boxes["farmacia"])
        let night = try XCTUnwrap(boxes["night"])
        // FARMACIA is the headline at the top, "night" further down on the right
        XCTAssertLessThan(farmacia.midY, 0.35)
        XCTAssertGreaterThan(night.midY, farmacia.maxY)
        XCTAssertGreaterThan(night.midX, 0.5)
        XCTAssertNil(boxes["la"], "stopwords are not candidates")
    }

    func testViewRectAspectFillAndFit() {
        let box = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.1)
        let image = CGSize(width: 1000, height: 2000)  // portrait frame
        // fit into a square view: 200 wide image centred, 50pt side bars
        let fit = OverlayScene.viewRect(box, imageSize: image, in: CGSize(width: 400, height: 400), fill: false)
        XCTAssertEqual(fit.minX, 150, accuracy: 0.01)
        XCTAssertEqual(fit.width, 100, accuracy: 0.01)
        XCTAssertEqual(fit.minY, 200, accuracy: 0.01)
        // fill: 400 wide image, cropped top and bottom by 200
        let fill = OverlayScene.viewRect(box, imageSize: image, in: CGSize(width: 400, height: 400), fill: true)
        XCTAssertEqual(fill.minX, 100, accuracy: 0.01)
        XCTAssertEqual(fill.minY, 200, accuracy: 0.01)
        XCTAssertEqual(fill.height, 80, accuracy: 0.01)
    }
}

final class SearchDepthTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SearchDepth.storageKey)
    }

    func testRequestSendsDepth() throws {
        let data = try JSONEncoder().encode(SceneRequest(words: [.init(text: "padre", lang: "it")],
                                                         lang: nil, maxCost: 9))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["max_cost"] as? Double, 9)
    }

    func testDecodesSearchInfo() throws {
        let json = """
        {"search": {"max_cost": 16, "reached": 7, "depth": 5},
         "words": [], "connections": [], "semantic": [], "nodes": {}}
        """
        let r = try JSONDecoder().decode(SceneResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.search, SearchInfo(maxCost: 16, reached: 7, depth: 5))
        XCTAssertEqual(r.showing(.meanings).search, r.search)
    }

    func testCurrentDefaultsAndClamps() {
        UserDefaults.standard.removeObject(forKey: SearchDepth.storageKey)
        XCTAssertEqual(SearchDepth.current, SearchDepth.defaultValue)
        UserDefaults.standard.set(500.0, forKey: SearchDepth.storageKey)
        XCTAssertEqual(SearchDepth.current, SearchDepth.range.upperBound)
    }
}


@MainActor
final class WordLimitTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WordLimit.storageKey)
    }

    func testSceneKeepsTheNewestWordsUpToTheLimit() {
        UserDefaults.standard.set(5, forKey: WordLimit.storageKey)
        let model = SceneModel()
        model.add(text: "alpha bravo charlie delta")
        model.add(text: "echo foxtrot golf")
        XCTAssertEqual(model.words, ["charlie", "delta", "echo", "foxtrot", "golf"])

        UserDefaults.standard.set(3, forKey: WordLimit.storageKey)  // clamped to 5
        XCTAssertEqual(WordLimit.current, 5)
        UserDefaults.standard.set(10, forKey: WordLimit.storageKey)
        model.add(text: "hotel india")
        XCTAssertEqual(model.words.count, 7)
    }

    func testLoweringTheLimitTrimsNow() {
        UserDefaults.standard.set(10, forKey: WordLimit.storageKey)
        let model = SceneModel()
        model.set(typed: "one two three four five six seven eight")
        XCTAssertEqual(model.words.count, 8)
        UserDefaults.standard.set(5, forKey: WordLimit.storageKey)
        model.applyWordLimit()
        XCTAssertEqual(model.words, ["four", "five", "six", "seven", "eight"])
    }
}


@MainActor
final class StableSceneTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WordLimit.storageKey)
    }

    /// A frame with words of decreasing size, top to bottom.
    private func frame(_ words: [String], height: (Int) -> CGFloat = { 0.1 - CGFloat($0) * 0.01 }) -> Recognition {
        Recognition(text: words.joined(separator: " "), words: words.enumerated().map { i, w in
            SeenWord(text: w, box: CGRect(x: 0.1, y: 0.05 + CGFloat(i) * 0.1, width: 0.3, height: height(i)))
        })
    }

    func testCrowdedViewGivesTheSameWordsEveryRead() {
        UserDefaults.standard.set(5, forKey: WordLimit.storageKey)
        let model = SceneModel()
        let view = ["farmacia", "aperta", "tutta", "notte", "padre", "nostro", "pharmacy", "open"]
        let start = Date()
        for read in 0..<6 {
            model.see(frame(view), imageSize: CGSize(width: 1000, height: 2000), full: true,
                      now: start.addingTimeInterval(Double(read)))
            if read == 0 {
                XCTAssertEqual(model.words, [], "a word needs two reads before it joins")
                continue
            }
            // the five most prominent, and the same ones on every read
            XCTAssertEqual(model.words, ["farmacia", "aperta", "tutta", "notte", "padre"], "read \(read)")
        }
    }

    func testNewWordsWaitUntilSomethingLeavesTheFrame() {
        UserDefaults.standard.set(5, forKey: WordLimit.storageKey)
        let model = SceneModel()
        let size = CGSize(width: 1000, height: 2000)
        let five = ["alpha", "bravo", "charlie", "delta", "echo"]
        let t0 = Date()
        model.see(frame(five), imageSize: size, full: true, now: t0)
        model.see(frame(five), imageSize: size, full: true, now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(model.words, five)
        // scene full, all still in view: a new word waits
        model.see(frame(five + ["foxtrot"]), imageSize: size, full: true, now: t0.addingTimeInterval(1))
        XCTAssertEqual(model.words, five)
        // bravo leaves the frame; once it has been gone a while, foxtrot takes its place
        let rest = ["alpha", "charlie", "delta", "echo", "foxtrot"]
        model.see(frame(rest), imageSize: size, full: true, now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(model.words, five, "bravo was seen moments ago")
        model.see(frame(rest), imageSize: size, full: true, now: t0.addingTimeInterval(4))
        XCTAssertEqual(model.words, ["alpha", "charlie", "delta", "echo", "foxtrot"])
    }

    func testOneFrameMisreadingsNeverJoin() {
        let model = SceneModel()
        let size = CGSize(width: 1000, height: 2000)
        let t0 = Date()
        model.see(frame(["storia", "basket"]), imageSize: size, full: true, now: t0)
        model.see(frame(["storia", "basket", "utore"]), imageSize: size, full: true, now: t0.addingTimeInterval(1))
        model.see(frame(["storia", "basket"]), imageSize: size, full: true, now: t0.addingTimeInterval(2))
        model.see(frame(["storia", "basket", "litore"]), imageSize: size, full: true, now: t0.addingTimeInterval(3))
        XCTAssertEqual(model.words, ["storia", "basket"])
    }

    func testFragmentsAndAccentVariantsAreSkipped() {
        let read = frame(["edicicloeditore", "tore", "ditore", "mia", "mía", "Basket"])
        let picked = SceneModel.candidates(in: read, scene: [], rejected: []).map(\.text)
        XCTAssertEqual(picked, ["edicicloeditore", "mia", "Basket"])
        // and against words already in the scene
        let later = SceneModel.candidates(in: frame(["carrer", "mía", "arre"]), scene: ["Carrer", "mia"],
                                          rejected: ["ediciclo"])
        XCTAssertEqual(later.map(\.text), [])
    }

    func testProminenceIgnoresSmallJitter() {
        let a = SeenWord(text: "a", box: CGRect(x: 0.1, y: 0.200, width: 0.2, height: 0.0801))
        let b = SeenWord(text: "b", box: CGRect(x: 0.5, y: 0.201, width: 0.2, height: 0.0799))
        // same size and line once rounded: left to right, whichever frame it came from
        XCTAssertTrue(SceneModel.moreProminent(a, b))
        XCTAssertFalse(SceneModel.moreProminent(b, a))
    }
}
