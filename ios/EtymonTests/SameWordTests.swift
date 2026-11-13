import XCTest
@testable import Etymon

/// Forms of one word (invitato, invitare) come back as a same-word link, not a shared root.
final class SameWordTests: XCTestCase {
    private let json = """
    {"words": [{"text": "invitare", "lang": "it", "terms": [7], "meanings": []},
               {"text": "invitato", "lang": "it", "terms": [7], "meanings": []},
               {"text": "padre", "lang": "it", "terms": [9], "meanings": []}],
     "connections": [], "semantic": [],
     "same_word": [{"a": 0, "b": 1, "lemma": 7}],
     "nodes": {"7": {"id": 7, "lang": "it", "language": "Italian", "word": "invitare",
                     "gloss": null, "reconstructed": false},
               "9": {"id": 9, "lang": "it", "language": "Italian", "word": "padre",
                     "gloss": null, "reconstructed": false}}}
    """

    private func decode(_ text: String) throws -> SceneResponse {
        try JSONDecoder().decode(SceneResponse.self, from: Data(text.utf8))
    }

    func testDecodesAndGroupsForms() throws {
        let r = try decode(json)
        XCTAssertEqual(r.sameWordLinks, [SameWord(a: 0, b: 1, lemma: 7)])
        let groups = StoryList.formGroups(r)
        XCTAssertEqual(groups.map(\.lemma), [7])
        XCTAssertEqual(groups.first?.words, [0, 1])
        // the Tree puts the two forms in one cluster, padre stays loose
        XCTAssertEqual(GraphLayout.clusters(r), [[0, 1]])
    }

    func testOlderBackendHasNone() throws {
        let older = json.replacingOccurrences(of: "\"same_word\": [{\"a\": 0, \"b\": 1, \"lemma\": 7}],", with: "")
        XCTAssertTrue(try decode(older).sameWordLinks.isEmpty)
    }

    func testLayersKeepForms() throws {
        XCTAssertEqual(try decode(json).showing(.roots).sameWordLinks.count, 1)
    }
}
