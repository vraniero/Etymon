import Foundation
import Observation
import simd

/// The word network behind a scene, for Explore: every node and link from the scene, and
/// whatever the user has expanded since. Structure only — positions live in ForceLayout.
@MainActor
@Observable
final class ExploreGraph: Identifiable {
    enum Role {
        case scene  // a word seen in the picture or video
        case meeting  // an ancestor shared by scene words
        case ancestor  // on a path between a scene word and a meeting point, or above
        case expanded  // brought in by expanding a node
    }

    struct XNode: Identifiable {
        let id: Int
        let label: String
        let language: String
        let lang: String
        let gloss: String?
        let reconstructed: Bool
        var role: Role
        var level: Int  // 0 = scene words; ancestors above, descendants below
        var expanded = false
        var totalChildren: Int?
    }

    /// child -> parent for descent; between two words of the same meaning otherwise.
    struct XEdge: Hashable {
        let a: Int
        let b: Int
        let kind: String  // edge kind, or "meaning"
        let meaning: String?
        var isMeaning: Bool { meaning != nil }
    }

    private(set) var nodes: [Int: XNode] = [:]
    private(set) var edges: Set<XEdge> = []
    /// Bumped on every structural change, so views redraw only when the network changes.
    private(set) var version = 0
    private(set) var sceneWords: [Int] = []
    /// For saved scenes: where each scene word was seen ("sign · Barcelona · 5 Nov 2026").
    var origins: [Int: [String]] = [:]

    init(response: SceneResponse, layers: NetworkLayers = .both) {
        let r = response.showing(layers)
        // a scene word is its first term; label it as it was read
        var wordNode: [Int: Int] = [:]
        for (i, word) in r.words.enumerated() {
            guard let id = word.terms.first else { continue }
            wordNode[i] = id
            if nodes[id] == nil, let n = r.node(id) {
                add(n, role: .scene, level: 0, label: word.text)
                sceneWords.append(id)
            }
        }
        for c in r.connections {
            for path in [c.pathA, c.pathB] {
                // the first step is the scene word's own term
                for (child, parent) in zip(path, path.dropFirst()) {
                    if let n = r.node(parent.node), nodes[parent.node] == nil {
                        add(n, role: .ancestor, level: 1)
                    }
                    edges.insert(XEdge(a: child.node, b: parent.node, kind: parent.kind ?? "derived",
                                       meaning: nil))
                }
            }
            let chain = [Step(node: c.meet, kind: nil)] + c.deeper
            for (child, parent) in zip(chain, chain.dropFirst()) {
                if let n = r.node(parent.node), nodes[parent.node] == nil {
                    add(n, role: .ancestor, level: 1)
                }
                edges.insert(XEdge(a: child.node, b: parent.node, kind: parent.kind ?? "derived",
                                   meaning: nil))
            }
            if nodes[c.meet]?.role != .scene { nodes[c.meet]?.role = .meeting }
        }
        for link in r.semanticLinks {
            if let a = wordNode[link.a], let b = wordNode[link.b] {
                edges.insert(XEdge(a: a, b: b, kind: "meaning", meaning: link.meaning))
            }
        }
        relevel()
        version += 1
    }

    /// Add a node's parents and children (GET /neighbors) around it.
    func expand(_ response: NeighborsResponse) {
        guard var center = nodes[response.node] else { return }
        for p in response.parents {
            if nodes[p.node] == nil, let n = response.nodes[String(p.node)] {
                add(n, role: .expanded, level: center.level + 1)
            }
            edges.insert(XEdge(a: response.node, b: p.node, kind: p.kind ?? "derived", meaning: nil))
        }
        for c in response.children {
            if nodes[c.node] == nil, let n = response.nodes[String(c.node)] {
                add(n, role: .expanded, level: center.level - 1)
            }
            edges.insert(XEdge(a: c.node, b: response.node, kind: c.kind ?? "derived", meaning: nil))
        }
        center.expanded = true
        center.totalChildren = response.totalChildren
        nodes[response.node] = center
        relevel()
        version += 1
    }

    /// Join scene words through their lineages (GET /word, cached on the device): each
    /// word's chain of ancestors is followed up to the first ancestor it shares with another
    /// scene word, which becomes a meeting point. This links words of different saved scenes
    /// (padre in one, paternalistic in another) without asking the server for a new scene.
    /// Chains are cut at `maxSteps` so links through distant roots stay out.
    func join(lineages: [Int: [Step]], nodes lineageNodes: [String: Node], maxSteps: Int = 8) {
        var chains: [Int: [Step]] = [:]
        for (term, steps) in lineages where nodes[term]?.role == .scene {
            chains[term] = Array(steps.prefix(maxSteps))
        }
        var sharedBy: [Int: Set<Int>] = [:]
        for (term, chain) in chains {
            for step in chain where step.node != term { sharedBy[step.node, default: []].insert(term) }
        }
        var changed = false
        for (term, chain) in chains.sorted(by: { $0.key < $1.key }) {
            // a scene word that is itself an ancestor of another (pater) also meets there
            guard let k = chain.firstIndex(where: {
                (sharedBy[$0.node]?.count ?? 0) >= 2 || (nodes[$0.node]?.role == .scene && $0.node != term)
            }) else { continue }
            var child = term
            for step in chain[...k] {
                if nodes[step.node] == nil, let n = lineageNodes[String(step.node)] {
                    add(n, role: .ancestor, level: 1)
                }
                guard nodes[step.node] != nil else { break }
                edges.insert(XEdge(a: child, b: step.node, kind: step.kind ?? "derived", meaning: nil))
                child = step.node
                changed = true
            }
            if nodes[chain[k].node]?.role == .ancestor { nodes[chain[k].node]?.role = .meeting }
        }
        guard changed else { return }
        relevel()
        version += 1
    }

    /// Nodes linked to `id`: where it comes from, what came from it, same meaning.
    func neighbors(of id: Int) -> (parents: [XEdge], children: [XEdge], meanings: [XEdge]) {
        var parents: [XEdge] = [], children: [XEdge] = [], meanings: [XEdge] = []
        for e in edges {
            if e.isMeaning {
                if e.a == id || e.b == id { meanings.append(e) }
            } else if e.a == id {
                parents.append(e)
            } else if e.b == id {
                children.append(e)
            }
        }
        let byLabel: (XEdge, XEdge) -> Bool = { [nodes] x, y in
            (nodes[x.a == id ? x.b : x.a]?.label ?? "") < (nodes[y.a == id ? y.b : y.a]?.label ?? "")
        }
        return (parents.sorted(by: byLabel), children.sorted(by: byLabel), meanings.sorted(by: byLabel))
    }

    private func add(_ n: Node, role: Role, level: Int, label: String? = nil) {
        nodes[n.id] = XNode(id: n.id, label: label ?? n.word, language: n.language, lang: n.lang,
                            gloss: n.gloss, reconstructed: n.reconstructed, role: role, level: level)
    }

    /// Every parent sits above all of its children: older words higher up.
    private func relevel() {
        for _ in 0..<64 {
            var changed = false
            for e in edges where !e.isMeaning {
                guard let child = nodes[e.a], let parent = nodes[e.b] else { continue }
                if parent.level <= child.level {
                    // keep scene words on the ground: move the other end
                    if child.role == .scene || parent.role != .scene {
                        nodes[e.b]!.level = child.level + 1
                    } else {
                        nodes[e.a]!.level = parent.level - 1
                    }
                    changed = true
                }
            }
            if !changed { break }
        }
    }
}

/// A force-directed 3D layout: links are springs, nodes repel each other, and each node is
/// drawn to the height of its level (older words higher). Dragged nodes stay pinned where
/// the user put them.
@MainActor
final class ForceLayout {
    private(set) var positions: [Int: SIMD3<Float>] = [:]
    private var velocities: [Int: SIMD3<Float>] = [:]
    var pinned: Set<Int> = []

    static let levelHeight: Float = 2.4
    static let springLength: Float = 2.8

    /// Bring the layout in line with the graph: new nodes start next to a linked node.
    func sync(_ graph: ExploreGraph) {
        for id in positions.keys where graph.nodes[id] == nil {
            positions[id] = nil
            velocities[id] = nil
        }
        var pending = graph.nodes.keys.filter { positions[$0] == nil }.sorted()
        var round = 0
        while !pending.isEmpty && round < 8 {
            pending = pending.filter { id in
                let node = graph.nodes[id]!
                let anchor = graph.edges.first {
                    ($0.a == id && positions[$0.b] != nil) || ($0.b == id && positions[$0.a] != nil)
                }.flatMap { positions[$0.a == id ? $0.b : $0.a] }
                if anchor == nil && round < 7 && !positions.isEmpty { return true }
                let base = anchor ?? .zero
                positions[id] = SIMD3(base.x + Self.jitter(id, 0) * 1.5,
                                      Float(node.level) * Self.levelHeight,
                                      base.z + Self.jitter(id, 1) * 1.5)
                velocities[id] = .zero
                return false
            }
            round += 1
        }
    }

    /// Beyond this distance nodes no longer push each other apart (the push there is
    /// ~1% of a spring's): only nearby pairs are computed, so large networks (a few
    /// hundred words, all saved scenes together) still move smoothly.
    static let repulsionRange: Float = 10

    /// One step of the simulation; returns how much the nodes moved.
    @discardableResult
    func step(_ graph: ExploreGraph, dt: Float = 1.0 / 60) -> Float {
        let ids = Array(positions.keys)
        let n = ids.count
        var index: [Int: Int] = [:]
        index.reserveCapacity(n)
        for (i, id) in ids.enumerated() { index[id] = i }
        let pos = ids.map { positions[$0]! }
        var force = [SIMD3<Float>](repeating: .zero, count: n)

        // repulsion between nearby nodes, found through a grid of repulsionRange cells
        let range = Self.repulsionRange
        let range2 = range * range
        func cell(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / range).rounded(.down)), Int32((p.y / range).rounded(.down)),
                  Int32((p.z / range).rounded(.down)))
        }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for i in 0..<n { grid[cell(pos[i]), default: []].append(i) }
        for i in 0..<n {
            let c = cell(pos[i])
            for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 {
                guard let others = grid[c &+ SIMD3(dx, dy, dz)] else { continue }
                for j in others where j > i {
                    var d = pos[i] - pos[j]
                    var len2 = simd_length_squared(d)
                    if len2 > range2 { continue }
                    if len2 < 0.0001 {
                        d = SIMD3(Self.jitter(ids[i], 2), 0.01, Self.jitter(ids[j], 2))
                        len2 = 0.0001
                    }
                    let f = d / len2 * (9.0 / max(sqrt(len2), 0.3))
                    force[i] += f
                    force[j] -= f
                }
            }}}
        }
        // springs
        for e in graph.edges {
            guard let a = index[e.a], let b = index[e.b] else { continue }
            let d = pos[b] - pos[a]
            let len = max(simd_length(d), 0.001)
            let rest = e.isMeaning ? Self.springLength * 1.2 : Self.springLength
            let f = d / len * (len - rest) * 1.6
            force[a] += f
            force[b] -= f
        }
        // height by level, gentle pull to the vertical axis
        for i in 0..<n {
            guard let node = graph.nodes[ids[i]] else { continue }
            let p = pos[i]
            let targetY = Float(node.level) * Self.levelHeight
            force[i] += SIMD3(-p.x * 0.05, (targetY - p.y) * 4.0, -p.z * 0.05)
        }
        var moved: Float = 0
        for i in 0..<n where !pinned.contains(ids[i]) {
            let id = ids[i]
            var v = (velocities[id] ?? .zero) + force[i] * dt
            v *= 0.85  // damping
            let speed = simd_length(v)
            if speed > 8 { v *= 8 / speed }
            velocities[id] = v
            positions[id] = pos[i] + v * dt
            moved += simd_length(v) * dt
        }
        return moved
    }

    func move(_ id: Int, to position: SIMD3<Float>) {
        positions[id] = position
        velocities[id] = .zero
    }

    func center(of ids: [Int]) -> SIMD3<Float> {
        let ps = ids.compactMap { positions[$0] }
        guard !ps.isEmpty else { return .zero }
        return ps.reduce(.zero, +) / Float(ps.count)
    }

    /// Deterministic small offset per node, so layouts are stable between runs.
    private static func jitter(_ id: Int, _ salt: Int) -> Float {
        var x = UInt64(truncatingIfNeeded: id &* 2654435761 &+ salt &* 40503)
        x ^= x >> 13; x &*= 0x5bd1e995; x ^= x >> 15
        return Float(x % 1000) / 500 - 1
    }
}
