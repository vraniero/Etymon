import CoreGraphics
import Foundation

/// Lays the scene out as layers: the words seen at the bottom, their ancestors above,
/// meeting points where two lines join. Positions are in layout units (x: slots,
/// y: levels) and scaled to the view by NetworkView.
struct GraphLayout {
    enum Key: Hashable {
        case word(Int)  // a word seen in the scene, by index
        case term(Int)  // an ancestor in the graph, by node id
    }

    struct Item: Identifiable {
        let key: Key
        var level: Int
        var x: CGFloat
        var isMeeting: Bool
        var id: Key { key }
    }

    struct Link: Hashable {
        let from: Key  // younger
        let to: Key  // older
        let kind: String?
    }

    private(set) var items: [Key: Item] = [:]
    private(set) var links: [Link] = []
    private(set) var maxLevel = 0
    private(set) var width: CGFloat = 1

    static let minSpacing: CGFloat = 1.25  // ancestor boxes are wider than a slot

    /// compact: draw each scene word straight to its meeting points (the common
    /// denominators); the full chains are in the detail sheet. Otherwise every step.
    /// only: restrict to a subset of scene words (one cluster); nil = all.
    init(_ response: SceneResponse, compact: Bool = true, only: Set<Int>? = nil) {
        let wordIndices = response.words.indices.filter { only?.contains($0) ?? true }
        let connections = response.connections.filter {
            only == nil || (only!.contains($0.a) && only!.contains($0.b))
        }
        var linkSet = Set<Link>()
        var meetings = Set<Key>()

        // a term that is itself a scene word (caffè, met by coffee) is drawn as that word
        var wordForTerm: [Int: Int] = [:]
        for (i, w) in response.words.enumerated() {
            for t in w.terms where wordForTerm[t] == nil { wordForTerm[t] = i }
        }
        func nodeKey(_ node: Int) -> Key { wordForTerm[node].map(Key.word) ?? .term(node) }

        func add(path: [Step], word: Int) {
            var child = Key.word(word)
            if compact, let last = path.last, path.count > 1 {
                let key = nodeKey(last.node)
                // single-step links keep their kind; collapsed chains are drawn neutral
                linkSet.insert(Link(from: child, to: key, kind: path.count == 2 ? last.kind : nil))
                return
            }
            for step in path.dropFirst() {
                let key = nodeKey(step.node)
                linkSet.insert(Link(from: child, to: key, kind: step.kind))
                child = key
            }
        }
        for c in connections {
            add(path: c.pathA, word: c.a)
            add(path: c.pathB, word: c.b)
            meetings.insert(nodeKey(c.meet))
        }

        // levels: words at 0, every ancestor above all of its descendants
        var level: [Key: Int] = [:]
        for i in wordIndices { level[.word(i)] = 0 }
        for link in linkSet { level[link.to] = max(level[link.to] ?? 1, 1) }
        for _ in 0..<32 {  // relax; paths are short, cycles are cut by the cap
            var changed = false
            for link in linkSet where (level[link.to] ?? 0) <= (level[link.from] ?? 0) {
                level[link.to] = (level[link.from] ?? 0) + 1
                changed = true
            }
            if !changed { break }
        }

        // x: words evenly spaced; ancestors centred over their children, then spread apart
        var x: [Key: CGFloat] = [:]
        let ordered = Self.wordOrder(response).filter { only?.contains($0) ?? true }
        for (slot, i) in ordered.enumerated() { x[.word(i)] = CGFloat(slot) * 1.2 }
        let top = level.values.max() ?? 0
        if top >= 1 {
            for l in 1...top {
                let keys = level.filter { $0.value == l }.map(\.key)
                for key in keys {
                    let children = linkSet.filter { $0.to == key }.compactMap { x[$0.from] }
                    x[key] = children.isEmpty ? 0 : children.reduce(0, +) / CGFloat(children.count)
                }
                let sorted = keys.sorted { (x[$0] ?? 0, Self.order($0)) < (x[$1] ?? 0, Self.order($1)) }
                var last = -CGFloat.infinity
                for key in sorted {
                    let pos = max(x[key] ?? 0, last + Self.minSpacing)
                    x[key] = pos
                    last = pos
                }
            }
        }

        for (key, l) in level {
            items[key] = Item(key: key, level: l, x: x[key] ?? 0, isMeeting: meetings.contains(key))
        }
        links = Array(linkSet)
        maxLevel = top
        let xs = items.values.map(\.x)
        let minX = xs.min() ?? 0
        for key in items.keys { items[key]!.x -= minX }
        width = max((xs.max() ?? 0) - minX, 1)
    }

    /// Every pair of related scene words: shared ancestry first (by distance), then
    /// same meaning.
    static func pairs(_ response: SceneResponse) -> [(a: Int, b: Int, distance: Double)] {
        response.connections.map { ($0.a, $0.b, $0.distance) }
            + response.semanticLinks.map { ($0.a, $0.b, 1000) }
    }

    /// Groups of scene words linked by shared ancestry or meaning, closest first. Words with no
    /// connection are not included.
    static func clusters(_ response: SceneResponse) -> [[Int]] {
        var group = Array(response.words.indices)  // union-find parents
        func find(_ i: Int) -> Int { group[i] == i ? i : find(group[i]) }
        let pairs = Self.pairs(response)
        for p in pairs { group[find(p.a)] = find(p.b) }
        let connected = Set(pairs.flatMap { [$0.a, $0.b] })
        var out: [Int: [Int]] = [:], firstSeen: [Int] = []
        for i in wordOrder(response) where connected.contains(i) {
            let root = find(i)
            if out[root] == nil { firstSeen.append(root) }
            out[root, default: []].append(i)
        }
        return firstSeen.map { out[$0]! }
    }

    /// Scene words ordered so that words sharing an ancestor sit side by side: closest
    /// connections first, then words with no connection at the end.
    static func wordOrder(_ response: SceneResponse) -> [Int] {
        var order: [Int] = []
        var placed = Set<Int>()
        func place(_ i: Int) { if placed.insert(i).inserted { order.append(i) } }
        let byDistance = pairs(response).sorted { $0.distance < $1.distance }
        // grow clusters: start from the closest pair, pull in words connected to the cluster
        var remaining = byDistance
        while let seed = remaining.first {
            place(seed.a); place(seed.b)
            var cluster: Set<Int> = [seed.a, seed.b]
            remaining.removeFirst()
            var grew = true
            while grew {
                grew = false
                if let k = remaining.firstIndex(where: { cluster.contains($0.a) || cluster.contains($0.b) }) {
                    let c = remaining.remove(at: k)
                    place(c.a); place(c.b)
                    cluster.formUnion([c.a, c.b])
                    grew = true
                }
            }
        }
        response.words.indices.forEach(place)
        return order
    }

    private static func order(_ key: Key) -> Int {
        switch key {
        case .word(let i): return i
        case .term(let id): return id
        }
    }
}
