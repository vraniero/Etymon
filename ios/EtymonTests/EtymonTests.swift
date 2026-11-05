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
