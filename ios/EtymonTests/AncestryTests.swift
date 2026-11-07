import XCTest
@testable import Etymon

/// A word made of several words has an ancestor for each: football goes back to foot and
/// to ball. Lineages carry, on each step, the node it goes up from.
@MainActor
final class AncestryTests: XCTestCase {
    private func node(_ id: Int, _ word: String, _ lang: String = "en") -> Node {
        Node(id: id, lang: lang, language: lang, word: word, gloss: nil,
             reconstructed: word.hasPrefix("*"), lat: nil, lon: nil)
    }

    /// football (1) <- fotbal (2) <- fot (3) <- *fōt (4); fotbal <- bal (5) <- *ballō (6);
    /// football <- foot (7) <- fot (3, already listed); a root stated on fot.
    private let football: [Step] = [
        Step(node: 2, kind: "inherited", from: 1), Step(node: 3, kind: "component", from: 2),
        Step(node: 4, kind: "inherited", from: 3), Step(node: 5, kind: "component", from: 2),
        Step(node: 6, kind: "inherited", from: 5), Step(node: 7, kind: "component", from: 1),
        Step(node: 3, kind: "inherited", from: 7), Step(node: 8, kind: "root", from: 3),
    ]

    private var nodes: [String: Node] {
        Dictionary(uniqueKeysWithValues: [
            node(1, "football"), node(2, "fotbal", "enm"), node(3, "fot", "enm"),
            node(4, "*fōt", "gmw-pro"), node(5, "bal", "enm"), node(6, "*ballō", "gmw-pro"),
            node(7, "foot"), node(8, "*ped-", "ine-pro"), node(9, "ball"),
        ].map { (String($0.id), $0) })
    }

    func testLinksFollowFrom() {
        let links = football.links(above: 1)
        XCTAssertEqual(links.map(\.child), [1, 2, 3, 2, 5, 1, 7, 3])
    }

    func testOlderBackendIsOneLine() {
        let line = [Step(node: 2, kind: "inherited"), Step(node: 3, kind: "inherited")]
        XCTAssertEqual(line.links(above: 1).map(\.child), [1, 2])
        XCTAssertEqual(line.mainLine(above: 1), line)
    }

    func testMainLineStopsAtTheFirstBranchButKeepsItsRoots() {
        XCTAssertEqual(football.mainLine(above: 1).map(\.node), [2, 3, 4, 8])
    }

    func testDecodesFrom() throws {
        let json = #"[{"node":2,"kind":"component","from":1},{"node":3,"kind":"inherited"}]"#
        let steps = try JSONDecoder().decode([Step].self, from: Data(json.utf8))
        XCTAssertEqual(steps[0].from, 1)
        XCTAssertNil(steps[1].from)
    }

    func testGrowAddsEveryBranch() {
        let graph = ExploreGraph()
        graph.grow(term: 1, label: "football", lineage: football, nodes: nodes)
        for id in [2, 3, 4, 5, 6, 7, 8] { XCTAssertNotNil(graph.nodes[id], "\(id)") }
        XCTAssertTrue(graph.edges.contains(.init(a: 2, b: 5, kind: "component", meaning: nil)))
        XCTAssertTrue(graph.edges.contains(.init(a: 7, b: 3, kind: "inherited", meaning: nil)))
    }

    func testGrowCutsEachBranchAtMaxSteps() {
        let graph = ExploreGraph()
        graph.grow(term: 1, label: "football", lineage: football, nodes: nodes, maxSteps: 2)
        XCTAssertNotNil(graph.nodes[5])  // fotbal, then bal: two steps
        XCTAssertNil(graph.nodes[6])
        XCTAssertNil(graph.nodes[4])
    }

    func testSceneDeeperBranches() {
        // football and fotbal meet at fotbal (2), with both its parts above it
        let deeper = [Step(node: 3, kind: "component", from: 2), Step(node: 4, kind: "inherited", from: 3),
                      Step(node: 5, kind: "component", from: 2), Step(node: 6, kind: "inherited", from: 5)]
        let r = SceneResponse(
            search: nil,
            words: [SceneWord(text: "football", lang: "en", terms: [1], meanings: nil),
                    SceneWord(text: "fotbal", lang: "enm", terms: [2], meanings: nil)],
            connections: [Connection(a: 0, b: 1, meet: 2, distance: 1, depth: 1,
                                     pathA: [Step(node: 1, kind: nil), Step(node: 2, kind: "inherited")],
                                     pathB: [Step(node: 2, kind: nil)], deeper: deeper)],
            semantic: nil, nodes: nodes)
        let graph = ExploreGraph(response: r)
        XCTAssertTrue(graph.edges.contains(.init(a: 2, b: 3, kind: "component", meaning: nil)))
        XCTAssertTrue(graph.edges.contains(.init(a: 2, b: 5, kind: "component", meaning: nil)))
        XCTAssertFalse(graph.edges.contains { $0.a == 4 && $0.b == 5 })  // not read as one line
    }

    func testJoinMeetsThroughASecondPart() {
        // football and ball (different saved scenes) meet at Middle English bal: football's
        // second branch, which a single line (fotbal, fot, *fōt) never reached.
        let graph = ExploreGraph(response: SceneResponse(
            search: nil,
            words: [SceneWord(text: "football", lang: "en", terms: [1], meanings: nil),
                    SceneWord(text: "ball", lang: "en", terms: [9], meanings: nil)],
            connections: [], semantic: nil, nodes: nodes))
        graph.join(lineages: [
            1: football,
            9: [Step(node: 5, kind: "inherited", from: 9), Step(node: 6, kind: "inherited", from: 5)],
        ], nodes: nodes)
        XCTAssertEqual(graph.nodes[5]?.role, .meeting)
        XCTAssertTrue(graph.edges.contains(.init(a: 2, b: 5, kind: "component", meaning: nil)))
        XCTAssertTrue(graph.edges.contains(.init(a: 1, b: 2, kind: "inherited", meaning: nil)))
        XCTAssertTrue(graph.edges.contains(.init(a: 9, b: 5, kind: "inherited", meaning: nil)))
        XCTAssertNil(graph.nodes[6])  // only up to where they meet
        XCTAssertNil(graph.nodes[4])  // football's other branch meets no one
    }
}
