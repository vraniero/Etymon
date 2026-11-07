import CoreGraphics
import Foundation
import SwiftData

/// A scene the user kept: its words and the network the backend found for them, the
/// picture they were read from, what it was (a sign, a menu, a book), where and when.
/// Everything needed to see it again is stored, so the saved network works offline.
@Model
final class SavedScene {
    var id: UUID
    var date: Date
    /// Camera, AR, Photo, Type or Talk.
    var source: String
    /// What the words were on, named by the user (suggested from the picture).
    var object: String
    /// What image classification thought it was, for search and as a fallback name.
    var objectGuesses: [String]
    var note: String
    var latitude: Double?
    var longitude: Double?
    /// Street, town, country: resolved when saved, so no lookup is needed later.
    var place: String?
    var language: String?
    var words: [String]
    /// The backend's SceneResponse, as JSON.
    var network: Data
    /// Where each word was in the picture: key -> [x, y, width, height], normalized.
    var boxes: [String: [Double]]
    var pictureWidth: Double
    var pictureHeight: Double
    @Attribute(.externalStorage) var picture: Data?
    @Attribute(.externalStorage) var thumbnail: Data?

    init(date: Date = .now, source: String, object: String, objectGuesses: [String] = [],
         note: String = "", latitude: Double? = nil, longitude: Double? = nil,
         place: String? = nil, language: String?, response: SceneResponse,
         boxes: [String: CGRect] = [:], pictureSize: CGSize = .zero,
         picture: Data? = nil, thumbnail: Data? = nil) {
        id = UUID()
        self.date = date
        self.source = source
        self.object = object
        self.objectGuesses = objectGuesses
        self.note = note
        self.latitude = latitude
        self.longitude = longitude
        self.place = place
        self.language = language
        words = response.words.map(\.text)
        network = (try? JSONEncoder().encode(response)) ?? Data()
        self.boxes = boxes.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
        pictureWidth = pictureSize.width
        pictureHeight = pictureSize.height
        self.picture = picture
        self.thumbnail = thumbnail
    }

    var response: SceneResponse? {
        try? JSONDecoder().decode(SceneResponse.self, from: network)
    }

    var wordBoxes: [String: CGRect] {
        boxes.compactMapValues { v in
            v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
        }
    }

    var pictureSize: CGSize { CGSize(width: pictureWidth, height: pictureHeight) }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// "padre" … : the name to show when the user gave none.
    var title: String {
        if !object.isEmpty { return object }
        return words.prefix(3).joined(separator: " · ")
    }
}

/// Every saved scene together: one network. Scenes join where they share a node (padre in
/// a church, paternal on a sign: both reach Latin pater), and words of different scenes
/// that mean the same thing are linked as well.
enum SavedNetwork {
    struct Merged {
        let response: SceneResponse
        /// For each scene word (term id), the scenes it was seen in.
        let origins: [Int: [UUID]]
    }

    @MainActor
    static func merge(_ scenes: [SavedScene]) -> Merged {
        merge(scenes.compactMap { s in s.response.map { (s.id, $0) } })
    }

    /// Words and links keep their own scene's numbering, shifted past the scenes before.
    static func merge(_ parts: [(id: UUID, response: SceneResponse)]) -> Merged {
        var words: [SceneWord] = []
        var connections: [Connection] = []
        var semantic: [SemanticLink] = []
        var nodes: [String: Node] = [:]
        var origins: [Int: [UUID]] = [:]
        var linked = Set<String>()

        for (id, r) in parts {
            let offset = words.count
            words += r.words
            nodes.merge(r.nodes) { a, _ in a }
            for c in r.connections {
                connections.append(Connection(a: c.a + offset, b: c.b + offset, meet: c.meet,
                                              distance: c.distance, depth: c.depth, pathA: c.pathA,
                                              pathB: c.pathB, deeper: c.deeper))
            }
            for l in r.semanticLinks {
                semantic.append(SemanticLink(a: l.a + offset, b: l.b + offset, meaning: l.meaning))
                linked.insert(pairKey(l.a + offset, l.b + offset))
            }
            for w in r.words {
                if let term = w.terms.first, origins[term]?.contains(id) != true {
                    origins[term, default: []].append(id)
                }
            }
        }

        // same meaning across scenes: words in different languages sharing a meaning key
        var byMeaning: [String: [Int]] = [:]
        for (i, w) in words.enumerated() {
            for m in w.meanings ?? [] { byMeaning[m, default: []].append(i) }
        }
        for (meaning, indices) in byMeaning.sorted(by: { $0.key < $1.key }) {
            for (n, i) in indices.enumerated() {
                for j in indices[(n + 1)...] {
                    let a = words[i], b = words[j]
                    guard a.lang != b.lang, a.terms.first != b.terms.first,
                          linked.insert(pairKey(i, j)).inserted else { continue }
                    semantic.append(SemanticLink(a: i, b: j, meaning: meaning))
                }
            }
        }

        let response = SceneResponse(search: nil, words: words, connections: connections,
                                     semantic: semantic, nodes: nodes)
        return Merged(response: response, origins: origins)
    }

    private static func pairKey(_ a: Int, _ b: Int) -> String { "\(min(a, b))-\(max(a, b))" }
}

extension ModelContainer {
    /// The app's store; `-memoryStore` (UI tests) keeps it in memory only.
    static func etymon(inMemory: Bool = ProcessInfo.processInfo.arguments.contains("-memoryStore"))
        -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: SavedScene.self, configurations: configuration)
        } catch {
            fatalError("Can't open the saved scenes: \(error)")
        }
    }
}
