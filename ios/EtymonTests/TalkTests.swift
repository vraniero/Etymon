import XCTest
@testable import Etymon

final class ConversationTests: XCTestCase {
    func testDecodesServerEvents() throws {
        let utterance = """
        {"type": "utterance", "id": 3, "persona": "P2", "new_persona": true, "similarity": 0.1,
         "lang": "it", "start": 12.4, "end": 15.1, "text": "La farmacia",
         "words": [{"text": "La", "start": 12.4, "end": 12.6}, {"text": "farmacia", "start": 12.6, "end": 13.1}]}
        """
        guard case .utterance(let u) = ConversationStream.event(from: Data(utterance.utf8)) else {
            return XCTFail("not an utterance")
        }
        XCTAssertEqual(u.persona, "P2")
        XCTAssertTrue(u.newPersona)
        XCTAssertEqual(u.words.map(\.text), ["La", "farmacia"])
        guard case .speech(let at) = ConversationStream.event(from: Data(#"{"type":"speech","start":1.5}"#.utf8)) else {
            return XCTFail("not speech")
        }
        XCTAssertEqual(at, 1.5)
        XCTAssertNil(ConversationStream.event(from: Data("{}".utf8)))
        XCTAssertNil(u.detected)
    }

    func testDecodesWhatListeningIsDoing() {
        guard case .ready(let languages) = ConversationStream.event(
            from: Data(#"{"type":"ready","languages":["en","it"]}"#.utf8)) else { return XCTFail("not ready") }
        XCTAssertEqual(languages, ["en", "it"])
        guard case .silence(_, let kept) = ConversationStream.event(
            from: Data(#"{"type":"silence","end":2,"kept":false}"#.utf8)) else { return XCTFail("not silence") }
        XCTAssertFalse(kept)
        guard case .unheard = ConversationStream.event(
            from: Data(#"{"type":"unheard","start":1,"end":2}"#.utf8)) else { return XCTFail("not unheard") }
        let foreign = #"""
        {"type": "utterance", "id": 1, "persona": "P1", "new_persona": true, "similarity": 0,
         "lang": null, "detected": "ja", "start": 0, "end": 1, "text": "konnichiwa", "words": []}
        """#
        guard case .utterance(let u) = ConversationStream.event(from: Data(foreign.utf8)) else {
            return XCTFail("not an utterance")
        }
        XCTAssertNil(u.lang)
        XCTAssertEqual(u.detected, "ja")
    }

    func testMicrophoneLevelScale() {
        XCTAssertEqual(ConversationStream.level(rms: 0), 0)
        XCTAssertEqual(ConversationStream.level(rms: 1), 1)
        XCTAssertEqual(ConversationStream.level(rms: 0.01), 0.333, accuracy: 0.01)  // -40 dB
    }

    func testListenURLFollowsTheServer() {
        XCTAssertEqual(ConversationStream.url(base: URL(string: "http://192.168.1.5:8000")!)?.absoluteString,
                       "ws://192.168.1.5:8000/listen")
        XCTAssertEqual(ConversationStream.url(base: URL(string: "https://etymon.example")!)?.absoluteString,
                       "wss://etymon.example/listen")
    }
}

@MainActor
final class SpokenWordsTests: XCTestCase {
    func testRequestSendsEachSpokenWordsLanguage() throws {
        var captured: Data?
        URLProtocolStub.handler = { request in
            captured = request.httpBodyStreamData ?? request.httpBody
            return (200, Data(#"{"words":[],"connections":[],"nodes":{}}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let client = APIClient(baseURL: URL(string: "http://test")!, session: URLSession(configuration: config))
        let done = expectation(description: "sent")
        Task {
            _ = try? await client.scene(words: ["notte", "night", "sign"], lang: nil,
                                        wordLanguages: ["it", "en", nil])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let body = try XCTUnwrap(captured)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let words = json?["words"] as? [[String: Any]]
        XCTAssertEqual(words?.map { $0["lang"] as? String }, ["it", "en", nil])
    }
}

/// Answers requests without a network.
final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession hands protocols the body as a stream.
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@MainActor
final class TalkTests: XCTestCase {
    static func node(_ id: Int, _ word: String, _ lang: String, reconstructed: Bool = false) -> [String: Any] {
        ["id": id, "lang": lang, "language": lang, "word": word, "reconstructed": reconstructed]
    }

    /// padre (it) and father (en) climb to *ph₂tḗr by different roads; notte stands alone.
    static let lineages: [String: (term: Int, chain: [Int], nodes: [[String: Any]])] = [
        "padre": (1, [1, 10, 20], [node(1, "padre", "it"), node(10, "pater", "la"),
                                   node(20, "*ph₂tḗr", "ine-pro", reconstructed: true)]),
        "father": (2, [2, 30, 20], [node(2, "father", "en"), node(30, "*fadēr", "gem-pro", reconstructed: true),
                                    node(20, "*ph₂tḗr", "ine-pro", reconstructed: true)]),
        "notte": (3, [3, 40], [node(3, "notte", "it"), node(40, "nox", "la")]),
    ]

    func makeSession() -> TalkSession {
        UserDefaults.standard.set(false, forKey: Chimes.storageKey)  // tests stay quiet
        URLProtocolStub.handler = { request in
            let url = request.url!
            if url.path.hasSuffix("/word"),
               let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "text" })?.value,
               let entry = Self.lineages[text] {
                let body: [String: Any] = [
                    "text": text, "lang": "x",
                    "entries": [["term": entry.term,
                                 "lineage": entry.chain.enumerated().map { i, n in
                                     ["node": n, "kind": i == 0 ? NSNull() : "inherited"] as [String: Any] }]],
                    "nodes": Dictionary(uniqueKeysWithValues: entry.nodes.map { (String($0["id"] as! Int), $0) }),
                ]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            }
            if url.path.hasSuffix("/word") { return (404, Data()) }
            return (200, Data(#"{"words":[],"connections":[],"nodes":{}}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let session = TalkSession()
        let urlSession = URLSession(configuration: config)
        session.client = {
            APIClient(baseURL: URL(string: "http://test")!, session: urlSession,
                      cache: OfflineCache(directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)))
        }
        return session
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Chimes.storageKey)
        URLProtocolStub.handler = nil
    }

    func testWordsGrowTreesAndConnectWhereTheyMeet() async {
        let talk = makeSession()
        await talk.heard(text: "mio padre", lang: "it", voice: "P1")
        XCTAssertEqual(talk.speakers.map(\.title), ["Speaker 1"])
        XCTAssertEqual(talk.graph.nodes[1]?.role, .scene)
        XCTAssertEqual(talk.graph.nodes[20]?.role, .ancestor)  // padre's tree, nothing shared yet
        XCTAssertEqual(talk.graph.connections.roots, 0)

        await talk.heard(text: "my father", lang: "en", voice: "P2")
        XCTAssertEqual(talk.speakers.map(\.number), [1, 2])
        XCTAssertEqual(talk.graph.nodes[20]?.role, .meeting)  // the two trees meet
        XCTAssertEqual(talk.graph.connections.roots, 1)
        XCTAssertEqual(talk.graph.speakers[1], 1)
        XCTAssertEqual(talk.graph.speakers[2], 2)
        XCTAssertEqual(talk.lastConnection, "*ph₂tḗr · father · padre")
        // older words higher: the root above both lines
        XCTAssertGreaterThan(talk.graph.nodes[20]!.level, talk.graph.nodes[10]!.level)

        await talk.heard(text: "notte xyzzy", lang: "it", voice: "P1")
        XCTAssertNotNil(talk.graph.nodes[3])  // its own tree, not connected
        XCTAssertEqual(talk.graph.connections.roots, 1)
        XCTAssertEqual(talk.speakers.first?.words, 2)  // padre, notte (xyzzy isn't a word)

        talk.clear()
        XCTAssertTrue(talk.isEmpty)
        XCTAssertNil(talk.lastConnection)
    }

    func testTheConnectionBannerFades() async {
        let talk = makeSession()
        await talk.heard(text: "padre", lang: "it", voice: "P1")
        await talk.heard(text: "father", lang: "en", voice: "P2")
        XCTAssertNotNil(talk.lastConnection)
        try? await Task.sleep(for: .seconds(TalkSession.connectionSeconds + 0.5))
        XCTAssertNil(talk.lastConnection)
    }

    func testTheCaptionShowsWhoSpokeThenFades() async {
        let talk = makeSession()
        await talk.heard(text: "padre", lang: "it", voice: "P1")
        XCTAssertEqual(talk.caption?.speaker, 1)
        XCTAssertEqual(talk.caption?.text, "padre")
        XCTAssertEqual(TalkSession.captionSeconds("padre"), 4, accuracy: 0.2)
        XCTAssertEqual(TalkSession.captionSeconds(String(repeating: "a", count: 1000)), 8)
        try? await Task.sleep(for: .seconds(4.5))
        XCTAssertNil(talk.caption)
    }

    func testEachWordSaidIsMarkedFoundOrMissing() async {
        let talk = makeSession()
        await talk.heard(text: "padre zzyzx", lang: "it", voice: "P1")
        XCTAssertEqual(talk.caption?.words["padre"], .found)
        XCTAssertEqual(talk.caption?.words["zzyzx"], .missing)
        XCTAssertEqual(talk.caption?.detected, "it")
        XCTAssertEqual(talk.wordsHeard, 2)
        XCTAssertEqual(talk.wordsFound, 1)
        XCTAssertEqual(talk.wordsPerMinute, 2)
        // said again: known at once, no new lookup
        await talk.heard(text: "padre", lang: "it", voice: "P2")
        XCTAssertEqual(talk.caption?.words["padre"], .found)
        XCTAssertEqual(talk.wordsFound, 2)
    }

    func testConnectTakesEveryWordOrTheChosenSpeakers() async {
        let talk = makeSession()
        await talk.heard(text: "padre notte", lang: "it", voice: "P1")
        await talk.heard(text: "father", lang: "en", voice: "P2")
        XCTAssertEqual(talk.connectWords.map(\.text), ["padre", "notte", "father"])
        talk.connectSpeakers = [2]
        XCTAssertEqual(talk.connectWords.map(\.text), ["father"])
        XCTAssertEqual(talk.connectWords.map(\.lang), ["en"])
    }

    func testThePhaseFollowsTheListening() {
        let talk = makeSession()
        XCTAssertEqual(talk.phase, .off)
        talk.handle(.speech(at: 0))
        talk.handle(.silence(at: 1, kept: true))
        talk.handle(.unheard)
        XCTAssertEqual(talk.notice, "Heard a sound — no words in it")
    }

    func testAWordSaidAgainTakesTheNewSpeakersColour() async {
        let talk = makeSession()
        await talk.heard(text: "padre", lang: "it", voice: "P1")
        await talk.heard(text: "padre", lang: "it", voice: "P2")
        XCTAssertEqual(talk.graph.speakers[1], 2)
        XCTAssertEqual(talk.graph.sceneWords, [1])
    }

    func testASpokenWordThatIsAnotherWordsAncestorConnectsToIt() {
        let graph = ExploreGraph()
        let nodes = ["1": Node(id: 1, lang: "it", language: "Italian", word: "padre", gloss: nil,
                               reconstructed: false, lat: nil, lon: nil),
                     "10": Node(id: 10, lang: "la", language: "Latin", word: "pater", gloss: nil,
                                reconstructed: false, lat: nil, lon: nil)]
        graph.grow(term: 1, label: "padre", lineage: [Step(node: 1, kind: nil), Step(node: 10, kind: "inherited")],
                   nodes: nodes, speaker: 1)
        XCTAssertEqual(graph.connections.roots, 0)
        graph.grow(term: 10, label: "pater", lineage: [Step(node: 10, kind: nil)], nodes: nodes, speaker: 2)
        XCTAssertEqual(graph.nodes[10]?.role, .scene)
        XCTAssertEqual(graph.connections.roots, 1)  // padre comes from pater, both said
    }
}

@MainActor
final class TreeDepthTests: XCTestCase {
    /// padre (speaker 1) and father (speaker 2) meet at *ph₂tḗr, one step up each; above it
    /// two more steps to the oldest known form. notte (speaker 1): nox, then *nókʷts on top.
    func graph() -> ExploreGraph {
        func n(_ id: Int, _ w: String) -> Node {
            Node(id: id, lang: "x", language: "X", word: w, gloss: nil, reconstructed: false, lat: nil, lon: nil)
        }
        let nodes = ["1": n(1, "padre"), "10": n(10, "pater"), "20": n(20, "*ph₂tḗr"),
                     "21": n(21, "x1"), "22": n(22, "x2"), "23": n(23, "oldest"),
                     "2": n(2, "father"), "30": n(30, "*fadēr"), "3": n(3, "notte"), "40": n(40, "nox"),
                     "50": n(50, "*nókʷts")]
        func chain(_ ids: [Int]) -> [Step] { ids.map { Step(node: $0, kind: "inherited") } }
        let g = ExploreGraph()
        g.grow(term: 1, label: "padre", lineage: chain([1, 10, 20, 21, 22, 23]), nodes: nodes, speaker: 1)
        g.grow(term: 2, label: "father", lineage: chain([2, 30, 20, 21, 22, 23]), nodes: nodes, speaker: 2)
        g.grow(term: 3, label: "notte", lineage: chain([3, 40, 50]), nodes: nodes, speaker: 1)
        return g
    }

    func shortcuts(_ g: ExploreGraph) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: g.edges.filter { $0.skipped > 0 }.map { ("\($0.a)>\($0.b)", $0.skipped) })
    }

    func testWordsAndRootsAlwaysStayMiddleStepsAreThinned() {
        let g = graph()
        XCTAssertEqual(g.shown(depth: TreeDepth.all).nodes.count, 11)
        let none = g.shown(depth: 0)
        // words, the shared root, the tops of the trees
        XCTAssertEqual(Set(none.nodes.keys), [1, 2, 3, 20, 23, 50])
        XCTAssertEqual(shortcuts(none), ["1>20": 1, "2>20": 1, "3>50": 1, "20>23": 2])
        XCTAssertEqual(none.nodes[20]?.role, .meeting)
        XCTAssertTrue(none.edges.allSatisfy { none.nodes[$0.a] != nil && none.nodes[$0.b] != nil })

        let one = g.shown(depth: 1)
        // the step nearest each word (and the one just above the root) come back
        XCTAssertEqual(Set(one.nodes.keys), [1, 2, 3, 10, 30, 40, 20, 21, 23, 50])
        XCTAssertEqual(shortcuts(one), ["21>23": 1])
        XCTAssertTrue(shortcuts(g.shown(depth: 2)).isEmpty)
    }

    func testPickingANodeShowsOnlyItsTree() {
        let g = graph()
        // the shared root: the words that meet there, the line above it; notte's tree goes
        let root = g.shown(depth: TreeDepth.all, focus: 20)
        XCTAssertEqual(Set(root.nodes.keys), [1, 10, 2, 30, 20, 21, 22, 23])
        XCTAssertEqual(Set(root.sceneWords), [1, 2])
        // a word: its own line only
        XCTAssertEqual(Set(g.shown(depth: TreeDepth.all, focus: 1).nodes.keys), [1, 10, 20, 21, 22, 23])
        // a middle step picked stays even with no middle steps shown
        let picked = g.shown(depth: 0, focus: 10)
        XCTAssertNotNil(picked.nodes[10])
        XCTAssertNil(picked.nodes[2])
    }

    func testPickingSpeakersShowsOnlyTheirWordsAndWhereTheyMeet() {
        let g = graph()
        let first = g.shown(depth: TreeDepth.all, speakers: [1])
        XCTAssertEqual(Set(first.sceneWords), [1, 3])
        XCTAssertNil(first.nodes[2])  // father is speaker 2's
        XCTAssertNil(first.nodes[30])  // nor its tree
        XCTAssertEqual(first.nodes[20]?.role, .ancestor)  // shared with someone not shown
        let both = g.shown(depth: TreeDepth.all, speakers: [1, 2])
        XCTAssertEqual(both.nodes[20]?.role, .meeting)
        XCTAssertEqual(Set(both.sceneWords), [1, 2, 3])
        // both filters at once: speaker 2 alone, no middle steps
        let lone = g.shown(depth: 0, speakers: [2])
        XCTAssertEqual(Set(lone.nodes.keys), [2, 23])  // father straight to the oldest form
        XCTAssertEqual(shortcuts(lone), ["2>23": 4])
    }
}

@MainActor
final class CollapseTests: XCTestCase {
    func testCollapseUndoesExpandAndWhatWasExpandedFromIt() {
        let g = TreeDepthTests().graph()  // padre, father, notte and their trees
        let before = (nodes: Set(g.nodes.keys), edges: g.edges)
        func n(_ id: Int) -> Node {
            Node(id: id, lang: "x", language: "X", word: "w\(id)", gloss: nil, reconstructed: false, lat: nil, lon: nil)
        }
        // expand pater (10): a new child (Pater, 60) and its known child padre (1)
        g.expand(NeighborsResponse(node: 10, parents: [Step(node: 20, kind: "inherited")],
                                   children: [Step(node: 60, kind: "borrowed"), Step(node: 1, kind: "inherited")],
                                   totalChildren: 2, meanings: [], nodes: ["60": n(60), "1": n(1), "20": n(20)]))
        XCTAssertNotNil(g.nodes[60])
        XCTAssertTrue(g.nodes[10]!.expanded)
        // then expand what it brought in: Pater's own child (70)
        g.expand(NeighborsResponse(node: 60, parents: [Step(node: 10, kind: "borrowed")],
                                   children: [Step(node: 70, kind: "derived")],
                                   totalChildren: 1, meanings: [], nodes: ["70": n(70), "10": n(10)]))
        XCTAssertNotNil(g.nodes[70])

        g.collapse(10)
        XCTAssertEqual(Set(g.nodes.keys), before.nodes)  // 60 and 70 gone, padre and pater stay
        XCTAssertEqual(g.edges, before.edges)  // padre -> pater was there before: kept
        XCTAssertFalse(g.nodes[10]!.expanded)
        g.collapse(10)  // nothing left to undo
        XCTAssertEqual(Set(g.nodes.keys), before.nodes)
    }
}

@MainActor
final class ExploreScopeTests: XCTestCase {
    /// TreeDepthTests' network (padre and father meet at *ph₂tḗr, with its own line above;
    /// notte alone) plus a same-meaning link between notte and father, for the test.
    func graph() -> ExploreGraph {
        let g = TreeDepthTests().graph()
        let response = SceneResponse(search: nil,
                                     words: [SceneWord(text: "notte", lang: "it", terms: [3], meanings: nil),
                                             SceneWord(text: "father", lang: "en", terms: [2], meanings: nil)],
                                     connections: [],
                                     semantic: [SemanticLink(a: 0, b: 1, meaning: "test")],
                                     nodes: [:])
        g.merge(response)
        return g
    }

    func testRootsKeepOnlyThePathsToSharedRoots() {
        let roots = graph().shown(depth: TreeDepth.all, scope: .roots)
        // padre and father up to *ph₂tḗr; not above it, not notte's lone line
        XCTAssertEqual(Set(roots.nodes.keys), [1, 10, 2, 30, 20])
        XCTAssertTrue(roots.edges.allSatisfy { !$0.isMeaning })
    }

    func testMeaningsKeepOnlyLinkedWords() {
        let meanings = graph().shown(depth: TreeDepth.all, scope: .meanings)
        XCTAssertEqual(Set(meanings.nodes.keys), [3, 2])
        XCTAssertEqual(meanings.edges.count, 1)
        XCTAssertTrue(meanings.edges.first!.isMeaning)
    }

    func testBothKeepEither() {
        let both = graph().shown(depth: TreeDepth.all, scope: .both)
        XCTAssertEqual(Set(both.nodes.keys), [1, 10, 2, 30, 20, 3])
        XCTAssertEqual(both.edges.filter(\.isMeaning).count, 1)
        XCTAssertEqual(graph().shown(depth: TreeDepth.all, scope: .whole).nodes.count, 11)
    }
}
