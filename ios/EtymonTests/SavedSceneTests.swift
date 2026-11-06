import SwiftData
import XCTest
@testable import Etymon

@MainActor
final class SavedSceneTests: XCTestCase {
    private func node(_ id: Int, _ word: String, _ lang: String = "la") -> Node {
        Node(id: id, lang: lang, language: lang, word: word, gloss: nil, reconstructed: false,
             lat: nil, lon: nil)
    }

    /// One word per scene: nothing connects it within its own scene.
    private func single(_ text: String, term: Int, lang: String, meanings: [String] = []) -> SceneResponse {
        SceneResponse(search: nil,
                      words: [SceneWord(text: text, lang: lang, terms: [term], meanings: meanings)],
                      connections: [], semantic: [],
                      nodes: [String(term): node(term, text, lang)])
    }

    func testSceneRoundTripsThroughTheStore() throws {
        let container = ModelContainer.etymon(inMemory: true)
        let fixture = try SceneResponseTests.fixture()
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        container.mainContext.insert(SavedScene(
            source: "Photo", object: "menu", latitude: 41.39, longitude: 2.16,
            place: "Carrer de Verdi, Barcelona", language: "it", response: fixture,
            boxes: ["padre": box], pictureSize: CGSize(width: 900, height: 1600)))
        try container.mainContext.save()

        let saved = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<SavedScene>()).first)
        XCTAssertEqual(saved.title, "menu")
        XCTAssertEqual(saved.words, ["caffè", "coffee", "padre", "paternalistic"])
        XCTAssertEqual(saved.response?.connections.count, fixture.connections.count)
        XCTAssertEqual(saved.wordBoxes["padre"], box)
        XCTAssertTrue(saved.hasLocation)
    }

    func testUnnamedSceneIsTitledByItsWords() {
        let scene = SavedScene(source: "Type", object: "", language: "en",
                               response: single("night", term: 1, lang: "en"))
        XCTAssertEqual(scene.title, "night")
    }

    func testMergeKeepsEachScenesLinksAndAddsMeaningsAcrossScenes() throws {
        let fixture = try SceneResponseTests.fixture()
        let a = UUID(), b = UUID(), c = UUID()
        let merged = SavedNetwork.merge([
            (a, fixture),
            (b, single("aperta", term: 900, lang: "it", meanings: ["open"])),
            (c, single("open", term: 901, lang: "en", meanings: ["open"])),
        ])
        let r = merged.response
        XCTAssertEqual(r.words.count, fixture.words.count + 2)
        XCTAssertEqual(r.connections.count, fixture.connections.count)  // indices unchanged: first
        XCTAssertTrue(r.semanticLinks.contains {
            Set([$0.a, $0.b]) == Set([fixture.words.count, fixture.words.count + 1]) && $0.meaning == "open"
        })
        XCTAssertEqual(merged.origins[900], [b])
        // the same word in two scenes is one node, seen in both
        let twice = SavedNetwork.merge([(a, fixture), (b, fixture)])
        let padre = try XCTUnwrap(fixture.words[2].terms.first)
        XCTAssertEqual(twice.origins[padre], [a, b])
        XCTAssertEqual(twice.response.connections.last?.a, fixture.connections.last!.a + fixture.words.count)
        let graph = ExploreGraph(response: twice.response)
        XCTAssertEqual(graph.sceneWords.count, fixture.words.count)
    }

    func testLineagesJoinWordsOfDifferentScenes() throws {
        // padre (one scene) and paternal (another) meet at Latin pater
        let merged = SavedNetwork.merge([
            (UUID(), single("padre", term: 1, lang: "it")),
            (UUID(), single("paternal", term: 2, lang: "en")),
        ])
        let graph = ExploreGraph(response: merged.response)
        XCTAssertTrue(graph.edges.isEmpty)
        let nodes = ["10": node(10, "patre"), "20": node(20, "paternalis"),
                     "30": node(30, "pater"), "40": node(40, "*ph₂tḗr", "ine-pro")]
        graph.join(lineages: [
            1: [Step(node: 10, kind: "inherited"), Step(node: 30, kind: "inherited"),
                Step(node: 40, kind: "inherited")],
            2: [Step(node: 20, kind: "borrowed"), Step(node: 30, kind: "derived"),
                Step(node: 40, kind: "inherited")],
        ], nodes: nodes)
        XCTAssertEqual(graph.nodes[30]?.role, .meeting)
        XCTAssertNil(graph.nodes[40])  // only up to where they meet
        XCTAssertTrue(graph.edges.contains(.init(a: 10, b: 30, kind: "inherited", meaning: nil)))
        XCTAssertTrue(graph.edges.contains(.init(a: 2, b: 20, kind: "borrowed", meaning: nil)))
        XCTAssertGreaterThan(graph.nodes[30]!.level, graph.nodes[10]!.level)
    }

    func testWordWithNoOneToMeetAddsNothing() {
        let graph = ExploreGraph(response: single("padre", term: 1, lang: "it"))
        let before = graph.version
        graph.join(lineages: [1: [Step(node: 10, kind: "inherited")]], nodes: ["10": node(10, "patre")])
        XCTAssertEqual(graph.version, before)
        XCTAssertEqual(graph.nodes.count, 1)
    }

    func testSavedSceneShowsWordsWhereTheyWere() throws {
        let model = SceneModel()
        let fixture = try SceneResponseTests.fixture()
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        model.show(saved: fixture, boxes: ["padre": box], imageSize: CGSize(width: 100, height: 200))
        XCTAssertEqual(model.words, fixture.words.map(\.text))
        XCTAssertNotNil(model.response)
        XCTAssertTrue(model.isVisible("padre", at: Date().addingTimeInterval(3600)))
        XCTAssertFalse(model.isVisible("coffee"))
    }

    func testCarefulReadsKeepTheirPictureForSaving() throws {
        let model = SceneModel()
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20))
            .image { _ in UIColor.white.setFill(); UIRectFill(.infinite) }.cgImage)
        var read = Recognition(text: "padre")
        read.words = [SeenWord(text: "padre", box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2))]
        model.see(read, imageSize: CGSize(width: 40, height: 20), full: true, still: true,
                  picture: .image(image, .up))
        let picture = try XCTUnwrap(model.picture)
        XCTAssertEqual(picture.boxes["padre"], read.words[0].box)
        XCTAssertEqual(picture.render(maxSide: 20)?.size, CGSize(width: 20, height: 10))
        model.reset()
        XCTAssertNil(model.picture)
    }
}

final class OfflineCacheTests: XCTestCase {
    private var cache: OfflineCache!

    override func setUp() {
        cache = OfflineCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "cache-\(UUID().uuidString)"))
    }

    override func tearDown() { cache.clear() }

    func testKeyIgnoresServerAndParameterOrder() {
        let a = OfflineCache.key(for: URL(string: "http://localhost:8000/word?text=padre&lang=it")!)
        let b = OfflineCache.key(for: URL(string: "http://192.168.1.2:8000/word?lang=it&text=padre")!)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, OfflineCache.key(for: URL(string: "http://x/word?text=madre&lang=it")!))
    }

    func testLookupsAnswerFromTheDeviceWhenTheServerIsGone() async throws {
        let json = #"{"text":"padre","lang":"it","entries":[{"term":1,"lineage":[]}],"nodes":{}}"#
        cache.store(Data(json.utf8), for: OfflineCache.key(for: URL(string: "http://h/word?text=padre&lang=it")!))
        // nothing listens on port 9: the request fails at once
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, cache: cache)
        let found = try await client.word("padre", lang: "it")
        XCTAssertEqual(found.entries.first?.term, 1)
        do {
            _ = try await client.word("madre", lang: "it")
            XCTFail("never looked up: should fail")
        } catch let error as APIClient.APIError {
            guard case .offline = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(cache.usage().count, 1)
    }
}
