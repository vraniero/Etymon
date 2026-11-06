import simd
import XCTest
@testable import Etymon

final class ConversationTests: XCTestCase {
    func testTalkingMouthScoresAboveAStillOne() {
        // 10 reads a second for 2 s: one mouth opening and closing, one barely moving
        let times = (0..<20).map { 100 + Double($0) / 10 }
        let talking = times.enumerated().map { ($1, Float($0 % 2 == 0 ? 0.02 : 0.08)) }
        let still = times.map { ($0, Float(0.03)) }
        let a = MouthActivity.score(talking, from: 100.2, to: 101.8)!
        let b = MouthActivity.score(still, from: 100.2, to: 101.8)!
        XCTAssertGreaterThan(a, MouthActivity.talking)
        XCTAssertLessThan(b, MouthActivity.talking)
        // not watched while it was said: no opinion
        XCTAssertNil(MouthActivity.score(talking, from: 110, to: 112))
    }

    func testFacesKeepTheirTrackAsTheyMove() {
        var tracker = FaceTracker()
        func face(_ x: CGFloat, open: Float = 0.05) -> FaceTracker.Face {
            .init(box: CGRect(x: x, y: 0.3, width: 0.2, height: 0.25), open: open, position: .zero, distance: 1)
        }
        tracker.update([face(0.1), face(0.6)], at: 1)
        tracker.update([face(0.15), face(0.62)], at: 1.1)
        XCTAssertEqual(tracker.tracks.map(\.id), [1, 2])
        XCTAssertEqual(tracker.tracks.map { $0.mouth.count }, [2, 2])
        tracker.update([face(0.62)], at: 1.2)  // the first left the picture
        tracker.update([face(0.62)], at: 1.2 + FaceTracker.forget + 0.1)
        XCTAssertEqual(tracker.tracks.map(\.id), [2])
        tracker.update([face(0.62), face(0.1)], at: 7)  // someone (new) at the left
        XCTAssertEqual(tracker.tracks.map(\.id), [2, 3])
    }

    func testWordsStackAboveTheSpeakerLatestLowest() {
        let head = SIMD3<Float>(0, 1.6, -2)
        let spots = Conversation.wordPositions(count: 5, around: head, distance: 2, right: SIMD3(1, 0, 0))
        XCTAssertEqual(spots.count, 5)
        XCTAssertTrue(spots.allSatisfy { $0.y > head.y })
        // the latest word is in the lowest row, centred over the head
        XCTAssertEqual(spots[4].x, head.x, accuracy: 0.001)
        XCTAssertEqual(spots[4].y, spots.map(\.y).min()!, accuracy: 0.001)
        XCTAssertGreaterThan(spots[0].y, spots[4].y)  // the oldest has risen
        // no two cards on the same spot
        for i in spots.indices { for j in spots.indices where j > i {
            XCTAssertGreaterThan(simd_distance(spots[i], spots[j]), 0.1)
        } }
    }

    func testOffCameraVoicesGoToAlternateSides() {
        let camera = matrix_identity_float4x4  // at the origin, looking down -z
        let first = Conversation.offCamera(camera: camera, slot: 0)
        let second = Conversation.offCamera(camera: camera, slot: 1)
        XCTAssertLessThan(first.z, -1)  // in front
        XCTAssertGreaterThan(first.x, 0.3)
        XCTAssertLessThan(second.x, -0.3)
    }

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
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WordLimit.storageKey)
    }

    func testSpokenWordsKeepTheLanguageTheyWereSaidIn() {
        UserDefaults.standard.set(10, forKey: WordLimit.storageKey)
        let model = SceneModel()
        let italian = model.hear("La farmacia è aperta tutta la notte", lang: "it")
        model.hear("My father says the pharmacy is open", lang: "en")
        XCTAssertTrue(italian.contains("farmacia"))
        XCTAssertEqual(model.spokenLanguages["farmacia"], "it")
        XCTAssertEqual(model.spokenLanguages["pharmacy"], "en")
        XCTAssertTrue(model.words.contains("notte") && model.words.contains("father"))
        model.reset()
        XCTAssertTrue(model.spokenLanguages.isEmpty)
    }

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
