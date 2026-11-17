import XCTest
@testable import Etymon

/// The backend on the phone must answer as the server does. Runs both on the same
/// dictionary — the mobile graph built on this Mac (the simulator sees its files) and a
/// server started on it:
///
///   cd backend && ETYMON_DB=../pipeline/data/etymon-mobile.sqlite \
///       .venv/bin/uvicorn app:app --port 8001
///
/// and compares their answers. Skipped when either is missing.
final class LocalBackendTests: XCTestCase {
    private static let database = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../pipeline/data/etymon-mobile.sqlite").standardized
    private static let server = URL(string: "http://127.0.0.1:8001")!

    private var local: LocalBackend!

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.database.path),
                          "no mobile graph (pipeline/export_mobile.py)")
        var health = URLRequest(url: Self.server.appending(path: "health"))
        health.timeoutInterval = 2
        let reachable = (try? await URLSession.shared.data(for: health)) != nil
        try XCTSkipUnless(reachable, "no server on the mobile graph at :8001")
        local = try LocalBackend(url: Self.database)
    }

    private func server(_ method: String, _ path: String, _ query: [String: String] = [:],
                        _ body: [String: Any]? = nil) async throws -> (Int, Any?) {
        var components = URLComponents(url: Self.server.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try? JSONSerialization.jsonObject(with: data))
    }

    private func phone(_ method: String, _ path: String, _ query: [String: String] = [:],
                       _ body: [String: Any]? = nil) async throws -> (Int, Any?) {
        do {
            let data = try await local.handle(method: method, path: path, query: query,
                                              body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
            return (200, try JSONSerialization.jsonObject(with: data))
        } catch let failure as LocalBackend.Failure {
            return (failure.status, nil)
        }
    }

    /// Both sides, compared after `shape` keeps what matters.
    private func same(_ method: String, _ path: String, _ query: [String: String] = [:],
                      _ body: [String: Any]? = nil, _ label: String,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let (a, x) = try await server(method, path, query, body)
        let (b, y) = try await phone(method, path, query, body)
        XCTAssertEqual(a, b, "\(label): status", file: file, line: line)
        guard a == 200 else { return }
        let left = Self.canonical(x), right = Self.canonical(y)
        if left != right {
            XCTFail("\(label) differs\nserver: \(left.prefix(1500))\nphone:  \(right.prefix(1500))",
                    file: file, line: line)
        }
    }

    /// JSON as sorted, comparable text; numbers rounded (Python and Swift print doubles
    /// alike only up to the last digit), nulls and absent keys alike.
    static func canonical(_ value: Any?) -> String {
        switch value {
        case let dict as [String: Any]:
            return "{" + dict.keys.sorted().compactMap { key in
                let v = dict[key]
                if v is NSNull { return nil }
                return "\(key):\(canonical(v))"
            }.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(canonical).joined(separator: ",") + "]"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return String(format: "%.6g", number.doubleValue)
        case let text as String:
            return "\"\(text)\""
        default:
            return "null"
        }
    }

    func testScenes() async throws {
        let scenes: [[[String: Any]]] = [
            [["text": "padre", "lang": "it"], ["text": "paternalistic", "lang": "en"]],
            [["text": "Farmacia"], ["text": "aperta"], ["text": "tutta"], ["text": "la"], ["text": "notte"],
             ["text": "padre"], ["text": "paternalistic"], ["text": "nocturnal"], ["text": "pharmacy"],
             ["text": "open"], ["text": "night"]],
            [["text": "football", "lang": "en"], ["text": "ball", "lang": "en"], ["text": "Fuß", "lang": "de"]],
            [["text": "ferrovia", "lang": "it"], ["text": "Eisenbahn", "lang": "de"]],
            [["text": "padre"], ["text": "padri"], ["text": "father"]],
            [["text": "молоко"], ["text": "mleko"], ["text": "milk"], ["text": "tej"]],
            [["text": "Handschuh"], ["text": "glove"], ["text": "hand"], ["text": "shoe"]],
        ]
        for (n, words) in scenes.enumerated() {
            try await same("POST", "scene", [:], ["words": words], "scene \(n)")
            try await same("POST", "scene", [:], ["words": words, "lang": "it"], "scene \(n), hint it")
            try await same("POST", "scene", [:], ["words": words, "max_cost": 8], "scene \(n), depth 8")
        }
    }

    func testWordsAndNeighbors() async throws {
        for (text, lang) in [("padri", "it"), ("football", "en"), ("Handschuh", "de"), ("ferrovia", nil),
                             ("notte", nil), ("xyzzy", nil), ("pharmacy", "en")] as [(String, String?)] {
            var query = ["text": text]
            if let lang { query["lang"] = lang }
            try await same("GET", "word", query, nil, "word \(text)")
        }
        // pater, and whatever padre's first ancestors are
        let (_, word) = try await phone("GET", "word", ["text": "padre", "lang": "it"])
        let entries = (word as? [String: Any])?["entries"] as? [[String: Any]] ?? []
        let ids = entries.flatMap { ($0["lineage"] as? [[String: Any]] ?? []).compactMap { $0["node"] as? Int } }
        XCTAssertFalse(ids.isEmpty)
        for id in ids.prefix(6) {
            try await same("GET", "neighbors", ["id": String(id), "children": "16"], nil, "neighbors \(id)")
        }
        try await same("GET", "neighbors", ["id": "999999999"], nil, "neighbors of nothing")
    }

    func testGameCheck() async throws {
        let (_, word) = try await phone("GET", "word", ["text": "padre", "lang": "it"])
        let lineage = ((word as? [String: Any])?["entries"] as? [[String: Any]])?.first?["lineage"] as? [[String: Any]] ?? []
        guard let root = lineage.dropFirst().first?["node"] as? Int else { return XCTFail("no ancestor") }
        try await same("POST", "games/check", [:],
                       ["root": root, "words": [["text": "paternal"], ["text": "padrino"], ["text": "chair"],
                                                ["text": "qwertyx"]]], "check")
    }

    /// The games pick at random, so their answers can't match the server's: each must
    /// come back in the shape the app reads.
    func testGamesAnswer() async throws {
        let decoder = JSONDecoder()
        for lang in ["it", "en", "de"] {
            let start = try await local.handle(method: "GET", path: "chain/start", query: ["lang": lang, "seed": "7"], body: nil)
            let opening = try JSONSerialization.jsonObject(with: start) as! [String: Any]
            let word = opening["text"] as! String
            let reply = try await local.handle(method: "POST", path: "chain/reply", query: [:], body:
                try JSONSerialization.data(withJSONObject: ["word": ["text": word, "lang": lang],
                                                            "used": [word], "level": "normal", "lang": lang]))
            XCTAssertNoThrow(try decoder.decode(ChainReply.self, from: reply))
            let impostor = try await local.handle(method: "GET", path: "games/impostor", query: ["lang": lang, "seed": "3"], body: nil)
            XCTAssertNoThrow(try decoder.decode(ImpostorPuzzle.self, from: impostor))
            let root = try await local.handle(method: "GET", path: "games/root", query: ["lang": lang, "seed": "3"], body: nil)
            XCTAssertNoThrow(try decoder.decode(GameRoot.self, from: root))
            let birth = try await local.handle(method: "GET", path: "games/birthplace", query: ["lang": lang, "seed": "3"], body: nil)
            XCTAssertNoThrow(try decoder.decode(BirthplacePuzzle.self, from: birth))
        }
    }

    func testSceneSpeed() async throws {
        let words = "Farmacia aperta tutta la notte padre paternalistic nocturnal pharmacy open night "
            + "football Handschuh ferrovia Eisenbahn молоко mleko milk father mother brother sister"
        let body = try JSONSerialization.data(withJSONObject: ["words": words.split(separator: " ").map { ["text": String($0)] }])
        let start = Date()
        _ = try await local.handle(method: "POST", path: "scene", query: [:], body: body)
        let seconds = Date().timeIntervalSince(start)
        let out = try JSONSerialization.jsonObject(with: try await local.handle(method: "POST", path: "scene", query: [:], body: body)) as! [String: Any]
        let connections = out["connections"] as! [[String: Any]]
        let nodes = out["nodes"] as! [String: [String: Any]]
        print("connections: \(connections.count), nodes: \(nodes.count), words: \((out["words"] as! [[String: Any]]).map { "\($0["text"]!)/\($0["lang"]!)/\(($0["terms"] as! [Int]).count)" })")
        XCTAssertGreaterThan(connections.count, 10)
        print("scene of 22 words on the phone's backend: \(String(format: "%.2f", seconds)) s")
        XCTAssertLessThan(seconds, 10)
    }
}
