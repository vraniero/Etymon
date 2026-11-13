import XCTest
@testable import Etymon

/// Root Chain's rules: what counts as a link, a miss, or not a move at all.
final class ChainTests: XCTestCase {
    /// father (en, 1) and padre (it, 2) meeting at *ph₂tḗr (3), or with no link at all.
    private func scene(second: String = "padre", lang: String = "it", terms: [Int] = [2],
                       linked: Bool = true, reconstructed: Bool = true) -> SceneResponse {
        let link = Connection(a: 0, b: 1, meet: 3, distance: 8, depth: 4,
                              pathA: [Step(node: 1, kind: nil), Step(node: 3, kind: "inherited")],
                              pathB: [Step(node: 2, kind: nil), Step(node: 3, kind: "inherited")],
                              deeper: [])
        let node = { (id: Int, lang: String, word: String, r: Bool) in
            Node(id: id, lang: lang, language: lang, word: word, gloss: nil, reconstructed: r,
                 lat: nil, lon: nil)
        }
        return SceneResponse(
            search: nil,
            words: [SceneWord(text: "father", lang: "en", terms: [1], meanings: nil),
                    SceneWord(text: second, lang: lang, terms: terms, meanings: nil)],
            connections: linked ? [link] : [], semantic: nil,
            nodes: ["1": node(1, "en", "father", false), "2": node(2, lang, second, false),
                    "3": node(3, "ine-pro", "*ph₂tḗr", reconstructed)])
    }

    private func judge(_ s: SceneResponse, played: Set<String> = ["father"],
                       terms: Set<Int> = [1], lastRoot: Int? = nil) -> ChainRules.Verdict {
        ChainRules.judge(s, played: played, playedTerms: terms, lastRoot: lastRoot)
    }

    func testLinkScoresLanguageAndAncientRoot() {
        guard case .link(_, let points) = judge(scene()) else { return XCTFail() }
        XCTAssertEqual(points, 3)  // link + new language + reconstructed ancestor
        guard case .link(_, let same) = judge(scene(second: "paternal", lang: "en",
                                                    reconstructed: false)) else { return XCTFail() }
        XCTAssertEqual(same, 1)
    }

    func testMisses() {
        XCTAssertEqual(judge(scene(linked: false)), .noLink)
        XCTAssertEqual(judge(scene(), lastRoot: 3), .sameRoot)
        XCTAssertEqual(judge(scene(), played: ["father", "padre"]), .played(before: "padre"))
        // a form of a word already played: padri after padre
        XCTAssertEqual(judge(scene(second: "padri"), terms: [1, 2]), .played(before: "padri"))
    }

    func testUnknownWordIsNotAMove() {
        XCTAssertEqual(judge(scene(second: "qwzxv", terms: [], linked: false)), .unknown)
    }

    /// A pass costs nothing yet; when everyone has passed on a word it's a dead end:
    /// still nobody loses a life, and a new word is drawn.
    @MainActor
    func testDeadEndDrawsANewWordAndCostsNothing() async throws {
        let game = ChainGame(opponent: .friend, start: "father")
        game.pass()
        XCTAssertEqual(game.turn, 1)
        XCTAssertEqual(game.players[0].lives, ChainRules.lives)
        game.pass()
        for _ in 0..<150 where game.moves.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(game.moves.count, 2, "a new word after the dead end")
        XCTAssertNotNil(game.moves[1].note)
        XCTAssertNotEqual(game.moves[1].text, "father")
        XCTAssertEqual(game.players.map(\.lives), [ChainRules.lives, ChainRules.lives])
        XCTAssertNil(game.winner)
    }
}

/// Up to six: turns go round; Etymon joins after the people.
final class ChainPlayersTests: XCTestCase {
    @MainActor
    func testSixPlayersTakeTurns() {
        let names = ["A", "B", "C", "D", "E", "F", "G"]
        let game = ChainGame(opponent: .friend, names: names, start: "father")
        XCTAssertEqual(game.players.count, 6, "six at most")
        for expected in [1, 2, 3, 4, 5] {
            game.pass()
            XCTAssertEqual(game.turn, expected)
        }
        XCTAssertTrue(game.players.allSatisfy { $0.lives == ChainRules.lives })
    }

    @MainActor
    func testEtymonJoinsAfterThePeople() {
        let game = ChainGame(opponent: .app(.easy), names: ["A", "B", "C", "D", "E", "F"], start: "father")
        XCTAssertEqual(game.players.map(\.name), ["A", "B", "C", "D", "E", "Etymon"])
        XCTAssertTrue(game.players.last!.isApp)
    }
}

/// The games' languages: all twenty, the Cyrillic ones among them, named in the phone's language.
final class GameLanguageTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(GameLanguage.name("uk"), TalkCaption.name("uk"))
        XCTAssertEqual(GameLanguage.name(nil), "Any language")
        XCTAssertEqual(GameLanguage.all.count, 20)
        for code in ["ru", "uk", "be", "bg", "mk", "sh"] { XCTAssertTrue(GameLanguage.all.contains(code)) }
    }
}
