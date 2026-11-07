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

/// How many of the steps between a word and its root are drawn, in Explore, Talk and AR.
/// Words and roots are always drawn; along each line the steps nearest the word are kept and
/// the rest are skipped, the line jumping straight on to the root. A view setting: the
/// search still goes as deep as SearchDepth says.
enum TreeDepth {
    static let storageKey = "treeMiddleSteps"
    static let all = -1
    static let defaultValue = all
    static let choices = [0, 1, 2, 3, 4, 6]

    static var current: Int {
        UserDefaults.standard.object(forKey: storageKey) as? Int ?? defaultValue
    }

    static func title(_ steps: Int) -> String {
        switch steps {
        case all: return "All steps"
        case 0: return "Words and roots only"
        case 1: return "1 step between"
        default: return "\(steps) steps between"
        }
    }

    /// Short, for buttons: "All" or "2".
    static func short(_ steps: Int) -> String { steps == all ? "All" : "\(steps)" }
}

/// How many words a scene can hold at once: past this the oldest drop off. Set in Settings.
enum WordLimit {
    static let storageKey = "maxWords"
    static let defaultValue = 20
    static let range = 5...200  // backend accepts up to 500 (backend/app.py MAX_WORDS)

    /// Steps of 5 up to 50, then of 10: fine control where it matters, quick to go high.
    static func step(at value: Int) -> Int { value < 50 ? 5 : 10 }
    static func next(after value: Int) -> Int {
        min((value / step(at: value) + 1) * step(at: value), range.upperBound)
    }
    static func previous(before value: Int) -> Int {
        let step = value <= 50 ? 5 : 10
        return max(((value - 1) / step) * step, range.lowerBound)
    }

    static var current: Int {
        let stored = UserDefaults.standard.integer(forKey: storageKey)
        return stored == 0 ? defaultValue : min(max(stored, range.lowerBound), range.upperBound)
    }
}

/// How deep the search that produced a scene went.
struct SearchInfo: Codable, Hashable {
    let maxCost: Double  // the depth asked for
    let reached: Double  // how far the deepest climb actually got (stops early when the data runs out)
    let depth: Double  // what the deepest connection found needs (0 if none)

    enum CodingKeys: String, CodingKey {
        case reached, depth
        case maxCost = "max_cost"
    }
}

struct Step: Codable, Hashable {
    let node: Int
    let kind: String?  // edge used to reach this node; nil for the starting word
}

struct Connection: Codable, Hashable, Identifiable {
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

struct Node: Codable, Hashable, Identifiable {
    let id: Int
    let lang: String
    let language: String
    let word: String
    let gloss: String?
    let reconstructed: Bool
    let lat: Double?  // where the language was spoken; nil if unknown or from an older backend
    let lon: Double?
}

struct SceneWord: Codable, Hashable {
    let text: String
    let lang: String?
    let terms: [Int]
    let meanings: [String]?

    var key: String { text.lowercased() }
}

/// Two scene words in different languages with the same meaning (aperta = open).
struct SemanticLink: Codable, Hashable, Identifiable {
    let a: Int
    let b: Int
    let meaning: String
    var id: String { "\(a)=\(b)" }
}

struct SceneResponse: Codable {
    let search: SearchInfo?  // absent from older backends
    let words: [SceneWord]
    let connections: [Connection]  // shared etymological ancestry
    let semantic: [SemanticLink]?  // same meaning across languages
    let nodes: [String: Node]  // JSON object keys are strings

    func node(_ id: Int) -> Node? { nodes[String(id)] }
    var semanticLinks: [SemanticLink] { semantic ?? [] }
}

struct WordResponse: Codable {
    struct Entry: Codable {
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

/// What Explore (and Talk) draws: the whole network, or only the paths that connect words —
/// through a shared root, by having the same meaning, or both.
enum ExploreScope: String, CaseIterable, Identifiable {
    case whole, roots, meanings, both
    static let storageKey = "exploreScope"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whole: return "Whole network"
        case .roots: return "Connections: shared roots"
        case .meanings: return "Connections: same meaning"
        case .both: return "Connections: both"
        }
    }
    var short: String {
        switch self {
        case .whole: return "All"
        case .roots: return "Roots"
        case .meanings: return "Meanings"
        case .both: return "Links"
        }
    }
    var keepsRoots: Bool { self == .roots || self == .both }
    var keepsMeanings: Bool { self == .meanings || self == .both }
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
struct NeighborsResponse: Codable {
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
