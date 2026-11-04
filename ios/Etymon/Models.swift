import Foundation

// Mirrors backend/app.py. Node ids are the graph's term ids.

struct SceneRequest: Encodable {
    struct Word: Encodable {
        let text: String
        let lang: String?
    }
    let words: [Word]
    let lang: String?
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
    let pathA: [Step]
    let pathB: [Step]
    let deeper: [Step]

    var id: String { "\(a)-\(b)-\(meet)" }

    enum CodingKeys: String, CodingKey {
        case a, b, meet, distance, deeper
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
}

struct SceneWord: Decodable, Hashable {
    let text: String
    let lang: String?
    let terms: [Int]
}

struct SceneResponse: Decodable {
    let words: [SceneWord]
    let connections: [Connection]
    let nodes: [String: Node]  // JSON object keys are strings

    func node(_ id: Int) -> Node? { nodes[String(id)] }
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
