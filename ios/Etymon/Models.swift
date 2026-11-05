import Foundation

// Mirrors backend/app.py. Node ids are the graph's term ids.

struct SceneRequest: Encodable {
    struct Word: Encodable {
        let text: String
        let lang: String?
    }
    let words: [Word]
    let lang: String?
    let maxCost: Double

    enum CodingKeys: String, CodingKey {
        case words, lang
        case maxCost = "max_cost"
    }
}

/// How far up each word's ancestry the backend climbs, in edge costs: most links cost 1,
/// a jump to a reconstructed root 6. Deeper finds older, more distant shared ancestors.
enum SearchDepth {
    static let storageKey = "searchDepth"
    static let defaultValue = 16.0  // pipeline/connect.py MAX_COST
    static let range = 2.0...40.0  // backend accepts 1...40

    static var current: Double {
        let stored = UserDefaults.standard.double(forKey: storageKey)
        return stored == 0 ? defaultValue : min(max(stored, range.lowerBound), range.upperBound)
    }
}

/// How deep the search that produced a scene went.
struct SearchInfo: Decodable, Hashable {
    let maxCost: Double  // the depth asked for
    let reached: Double  // how far the deepest climb actually got (stops early when the data runs out)
    let depth: Double  // what the deepest connection found needs (0 if none)

    enum CodingKeys: String, CodingKey {
        case reached, depth
        case maxCost = "max_cost"
    }
}

struct Step: Decodable, Hashable {
    let node: Int
    let kind: String?  // edge used to reach this node; nil for the starting word
}

struct Connection: Decodable, Hashable, Identifiable {
    let a: Int
    let b: Int
    let meet: Int
    let distance: Double
    let depth: Double?  // cost of the longer path: the search depth this connection needs
    let pathA: [Step]
    let pathB: [Step]
    let deeper: [Step]  // above meet (not including it), up to the oldest known root

    var id: String { "\(a)-\(b)-\(meet)" }

    enum CodingKeys: String, CodingKey {
        case a, b, meet, distance, depth, deeper
        case pathA = "path_a"
        case pathB = "path_b"
    }
}

struct Node: Decodable, Hashable, Identifiable {
    let id: Int
    let lang: String
    let language: String
    let word: String
    let gloss: String?
    let reconstructed: Bool
    let lat: Double?  // where the language was spoken; nil if unknown or from an older backend
    let lon: Double?
}

struct SceneWord: Decodable, Hashable {
    let text: String
    let lang: String?
    let terms: [Int]
    let meanings: [String]?

    var key: String { text.lowercased() }
}

/// Two scene words in different languages with the same meaning (aperta = open).
struct SemanticLink: Decodable, Hashable, Identifiable {
    let a: Int
    let b: Int
    let meaning: String
    var id: String { "\(a)=\(b)" }
}

struct SceneResponse: Decodable {
    let search: SearchInfo?  // absent from older backends
    let words: [SceneWord]
    let connections: [Connection]  // shared etymological ancestry
    let semantic: [SemanticLink]?  // same meaning across languages
    let nodes: [String: Node]  // JSON object keys are strings

    func node(_ id: Int) -> Node? { nodes[String(id)] }
    var semanticLinks: [SemanticLink] { semantic ?? [] }
}

struct WordResponse: Decodable {
    struct Entry: Decodable {
        let term: Int
        let lineage: [Step]
    }
    let text: String
    let lang: String?
    let entries: [Entry]
    let nodes: [String: Node]

    func node(_ id: Int) -> Node? { nodes[String(id)] }
}

/// Human wording for edge kinds.
func describe(kind: String?) -> String {
    switch kind {
    case "inherited": return "inherited from"
    case "borrowed": return "borrowed from"
    case "learned": return "learned borrowing from"
    case "calque": return "calque of"
    case "semantic_loan": return "meaning borrowed from"
    case "derived": return "from"
    case "component": return "built from"
    case "root": return "root"
    default: return ""
    }
}

/// Which kinds of connection the network shows: shared roots (etymological), same
/// meaning (semantic), or both side by side. Chosen by the user, remembered.
enum NetworkLayers: String, CaseIterable, Identifiable {
    case both, roots, meanings
    static let storageKey = "networkLayers"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "Both"
        case .roots: return "Roots"
        case .meanings: return "Meanings"
        }
    }
    var showsRoots: Bool { self != .meanings }
    var showsMeanings: Bool { self != .roots }
}

extension SceneResponse {
    /// The same scene with only the chosen kinds of connection.
    func showing(_ layers: NetworkLayers) -> SceneResponse {
        SceneResponse(search: search, words: words,
                      connections: layers.showsRoots ? connections : [],
                      semantic: layers.showsMeanings ? semanticLinks : [],
                      nodes: nodes)
    }
}

/// A node's immediate network, from GET /neighbors: where it comes from and what came from it.
struct NeighborsResponse: Decodable {
    let node: Int
    let parents: [Step]
    let children: [Step]
    let totalChildren: Int
    let meanings: [String]
    let nodes: [String: Node]

    enum CodingKeys: String, CodingKey {
        case node, parents, children, meanings, nodes
        case totalChildren = "total_children"
    }
}
