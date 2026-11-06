import simd
import XCTest
@testable import Etymon

final class WordLimitStepTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WordLimit.storageKey)
    }

    func testStepsOfFiveThenTen() {
        XCTAssertEqual(WordLimit.next(after: 20), 25)
        XCTAssertEqual(WordLimit.next(after: 45), 50)
        XCTAssertEqual(WordLimit.next(after: 50), 60)
        XCTAssertEqual(WordLimit.next(after: 190), 200)
        XCTAssertEqual(WordLimit.next(after: 200), 200)
        XCTAssertEqual(WordLimit.previous(before: 60), 50)
        XCTAssertEqual(WordLimit.previous(before: 50), 45)
        XCTAssertEqual(WordLimit.previous(before: 5), 5)
        XCTAssertEqual(WordLimit.next(after: 23), 25)  // off-step values snap onto the steps
        XCTAssertEqual(WordLimit.previous(before: 55), 50)
    }

    func testHundredsOfWordsAreAllowed() {
        UserDefaults.standard.set(200, forKey: WordLimit.storageKey)
        XCTAssertEqual(WordLimit.current, 200)
        UserDefaults.standard.set(900, forKey: WordLimit.storageKey)
        XCTAssertEqual(WordLimit.current, 200)
    }
}

@MainActor
final class LargeNetworkLayoutTests: XCTestCase {
    /// `count` unconnected scene words.
    private func graph(_ count: Int) -> ExploreGraph {
        var nodes: [String: Node] = [:]
        var words: [SceneWord] = []
        for i in 0..<count {
            nodes[String(i)] = Node(id: i, lang: "it", language: "Italian", word: "w\(i)", gloss: nil,
                                    reconstructed: false, lat: nil, lon: nil)
            words.append(SceneWord(text: "w\(i)", lang: "it", terms: [i], meanings: nil))
        }
        return ExploreGraph(response: SceneResponse(search: nil, words: words, connections: [],
                                                    semantic: [], nodes: nodes))
    }

    func testNodesStillSpreadApart() {
        let g = graph(60)
        let layout = ForceLayout()
        layout.sync(g)
        for _ in 0..<600 { layout.step(g) }
        let ps = Array(layout.positions.values)
        var closest = Float.infinity
        for i in 0..<ps.count { for j in (i + 1)..<ps.count { closest = min(closest, simd_distance(ps[i], ps[j])) } }
        XCTAssertGreaterThan(closest, 0.8, "nodes overlap")
    }

    func testThousandNodesStepWithinAFrame() {
        let g = graph(1300)
        let layout = ForceLayout()
        layout.sync(g)
        for _ in 0..<30 { layout.step(g) }  // spread out first
        let start = Date()
        for _ in 0..<10 { layout.step(g) }
        let perStep = Date().timeIntervalSince(start) / 10
        #if DEBUG
        // unoptimized code is tens of times slower: only check it doesn't blow up
        XCTAssertLessThan(perStep, 1, "one step took \(perStep) s")
        #else
        XCTAssertLessThan(perStep, 0.016, "one step should fit in a 60 fps frame")
        #endif
    }
}
