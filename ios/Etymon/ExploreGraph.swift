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
        /// A shortcut drawn when steps between a word and its root are hidden: how many.
        var skipped = 0
        var isMeaning: Bool { meaning != nil }
    }

    private(set) var nodes: [Int: XNode] = [:]
    private(set) var edges: Set<XEdge> = []
    /// Bumped on every structural change, so views redraw only when the network changes.
    private(set) var version = 0
    private(set) var sceneWords: [Int] = []
    /// For saved scenes: where each scene word was seen ("sign · Barcelona · 5 Nov 2026").
    var origins: [Int: [String]] = [:]
    /// Talk: who said each word (persona number, from 1), for its colour.
    private(set) var speakers: [Int: Int] = [:]
    /// Which spoken words reach each ancestor: two or more make it a shared root.
    private var reachedBy: [Int: Set<Int>] = [:]

    /// Connections in the network: shared roots, same-meaning links, and words that are
    /// themselves an ancestor of another word in it. Talk chimes when this grows.
    var connections: (roots: Int, meanings: Int) {
        let roots = nodes.values.filter { $0.role == .meeting }.count
            + edges.filter { !$0.isMeaning && nodes[$0.b]?.role == .scene && nodes[$0.a]?.role == .scene }.count
        return (roots, edges.filter(\.isMeaning).count)
    }

    /// An empty network, to grow (Talk).
    init() {}

    init(response: SceneResponse, layers: NetworkLayers = .both) {
        merge(response.showing(layers))
    }

    /// Add a scene's words, connections and same-meaning links to what is already here.
    func merge(_ r: SceneResponse) {
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
            if let a = wordNode[link.a], let b = wordNode[link.b], a != b,
               !edges.contains(where: { $0.isMeaning && Set([$0.a, $0.b]) == Set([a, b]) }) {
                edges.insert(XEdge(a: a, b: b, kind: "meaning", meaning: link.meaning))
            }
        }
        relevel()
        version += 1
    }

    /// A word just said, and its tree: the word on the ground, its line of ancestors above
    /// it (up to `maxSteps`). Where the line reaches an ancestor another word's line already
    /// reached, or another word said, the two are connected there.
    func grow(term: Int, label: String, lineage: [Step], nodes lineageNodes: [String: Node],
              speaker: Int? = nil, maxSteps: Int = 6) {
        if let existing = nodes[term] {
            if existing.role != .scene {
                // said now, but already here as someone else's ancestor (pater, then padre's)
                nodes[term]!.role = .scene
                sceneWords.append(term)
            }
        } else if let n = lineageNodes[String(term)] {
            add(n, role: .scene, level: 0, label: label)
            sceneWords.append(term)
        } else {
            return
        }
        if let speaker { speakers[term] = speaker }
        var child = term
        var met = false  // above the first ancestor shared, the line is already joined
        for step in lineage.filter({ $0.node != term }).prefix(maxSteps) {
            if nodes[step.node] == nil {
                guard let n = lineageNodes[String(step.node)] else { break }
                add(n, role: .ancestor, level: 1)
            }
            edges.insert(XEdge(a: child, b: step.node, kind: step.kind ?? "derived", meaning: nil))
            reachedBy[step.node, default: []].insert(term)
            if reachedBy[step.node]!.count >= 2 || nodes[step.node]?.role == .scene {
                if !met, nodes[step.node]?.role == .ancestor { nodes[step.node]!.role = .meeting }
                met = true
            }
            child = step.node
        }
        relevel()
        version += 1
    }

    /// What each Expand brought in, by the node expanded: so Collapse can take it away.
    private var expansions: [Int: (nodes: Set<Int>, edges: Set<XEdge>)] = [:]

    /// Add a node's parents and children (GET /neighbors) around it.
    func expand(_ response: NeighborsResponse) {
        guard var center = nodes[response.node] else { return }
        var added: (nodes: Set<Int>, edges: Set<XEdge>) = ([], [])
        for p in response.parents {
            if nodes[p.node] == nil, let n = response.nodes[String(p.node)] {
                add(n, role: .expanded, level: center.level + 1)
                added.nodes.insert(p.node)
            }
            let e = XEdge(a: response.node, b: p.node, kind: p.kind ?? "derived", meaning: nil)
            if edges.insert(e).inserted { added.edges.insert(e) }
        }
        for c in response.children {
            if nodes[c.node] == nil, let n = response.nodes[String(c.node)] {
                add(n, role: .expanded, level: center.level - 1)
                added.nodes.insert(c.node)
            }
            let e = XEdge(a: c.node, b: response.node, kind: c.kind ?? "derived", meaning: nil)
            if edges.insert(e).inserted { added.edges.insert(e) }
        }
        expansions[response.node] = added
        center.expanded = true
        center.totalChildren = response.totalChildren
        nodes[response.node] = center
        relevel()
        version += 1
    }

    /// Undo an Expand: the nodes and links it brought in go, and with them whatever was
    /// expanded from those nodes since. Nodes that were there before, or that something
    /// else still links in, stay.
    func collapse(_ id: Int) {
        guard let added = expansions.removeValue(forKey: id) else { return }
        // expansions made from nodes that are going go first
        for node in added.nodes where expansions[node] != nil { collapse(node) }
        edges.subtract(added.edges)
        for node in added.nodes where nodes[node]?.role == .expanded {
            let stillLinked = edges.contains { $0.a == node || $0.b == node }
            if !stillLinked { nodes[node] = nil }
        }
        nodes[id]?.expanded = false
        nodes[id]?.totalChildren = nil
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

    /// The part of the network to draw: the words said by `speakers` (empty: everyone) with
    /// everything above them (and what Expand brought in around those), and of the steps
    /// between, at most `middle` per line (`TreeDepth.all`: every one). Another speaker's
    /// branch shows only where it is also the branch of a word shown: picking a speaker
    /// shows their words alone, picking two shows where they meet.
    ///
    /// With `focus` (a node picked), only its tree: it, everything above it, and everything
    /// that came from it below.
    ///
    /// `scope` other than `.whole` keeps only the paths that connect words (see
    /// `keepConnections`).
    func shown(depth middle: Int, speakers chosen: Set<Int> = [], focus: Int? = nil,
               scope: ExploreScope = .whole) -> ExploreGraph {
        guard middle != TreeDepth.all || !chosen.isEmpty || focus != nil || scope != .whole,
              !sceneWords.isEmpty else { return self }
        let allowed = sceneWords.filter { chosen.isEmpty || chosen.contains(speakers[$0] ?? 0) }
        let allowedSet = Set(allowed)
        let sceneSet = Set(sceneWords)
        // up the lines of descent (child -> parent); down only into what Expand brought in,
        // never into another word's branch
        var adjacent: [Int: [Int]] = [:]
        for e in edges where !e.isMeaning {
            adjacent[e.a, default: []].append(e.b)
            if nodes[e.a]?.role == .expanded { adjacent[e.b, default: []].append(e.a) }
        }
        var reachable = allowedSet
        var queue = allowed
        while let id = queue.popLast() {
            for next in adjacent[id] ?? [] where !reachable.contains(next) {
                if sceneSet.contains(next), !allowedSet.contains(next) { continue }
                reachable.insert(next)
                queue.append(next)
            }
        }
        if let focus, reachable.contains(focus) {
            var up: [Int: [Int]] = [:], down: [Int: [Int]] = [:]
            for e in edges where !e.isMeaning {
                up[e.a, default: []].append(e.b)
                down[e.b, default: []].append(e.a)
            }
            var tree: Set<Int> = [focus]
            for links in [up, down] {
                var stack = [focus]
                while let id = stack.popLast() {
                    for next in links[id] ?? [] where reachable.contains(next) && tree.insert(next).inserted {
                        stack.append(next)
                    }
                }
            }
            reachable = tree
        }
        let copy = ExploreGraph()
        copy.nodes = nodes.filter { reachable.contains($0.key) }
        copy.edges = edges.filter { copy.nodes[$0.a] != nil && copy.nodes[$0.b] != nil }
        copy.sceneWords = allowed.filter { reachable.contains($0) }
        copy.speakers = speakers.filter { allowedSet.contains($0.key) }
        copy.origins = origins
        copy.version = version
        // a shared root with only one of its words left in view is just an ancestor here
        var parents: [Int: [Int]] = [:]
        for e in copy.edges where !e.isMeaning { parents[e.a, default: []].append(e.b) }
        var reached: [Int: Int] = [:]
        for word in allowed {
            var seen: Set<Int> = [word]
            var stack = [word]
            while let id = stack.popLast() {
                for p in parents[id] ?? [] where seen.insert(p).inserted { stack.append(p) }
            }
            for id in seen where id != word { reached[id, default: 0] += 1 }
        }
        for (id, node) in copy.nodes where node.role == .meeting && (reached[id] ?? 0) < 2 {
            copy.nodes[id]!.role = .ancestor
        }
        if scope != .whole { copy.keepConnections(scope, besides: focus) }
        if middle != TreeDepth.all { copy.skipMiddleSteps(keeping: middle, besides: focus) }
        return copy
    }

    /// Only the paths that connect words. Shared roots: each word's line up to every root
    /// it shares with another word (or to another word it descends from), and nothing past
    /// it. Same meaning: the words linked by meaning and their links. A word with no such
    /// connection goes; so does everything not on a connecting path.
    private func keepConnections(_ scope: ExploreScope, besides picked: Int? = nil) {
        var up: [Int: [Int]] = [:], down: [Int: [Int]] = [:]
        for e in edges where !e.isMeaning {
            up[e.a, default: []].append(e.b)
            down[e.b, default: []].append(e.a)
        }
        func closure(from start: Int, _ links: [Int: [Int]]) -> Set<Int> {
            var seen: Set<Int> = [start]
            var stack = [start]
            while let id = stack.popLast() {
                for next in links[id] ?? [] where seen.insert(next).inserted { stack.append(next) }
            }
            return seen
        }
        var keep = Set<Int>()
        if scope.keepsRoots {
            let words = Set(sceneWords)
            let above = Dictionary(uniqueKeysWithValues: sceneWords.map { ($0, closure(from: $0, up)) })
            // where lines meet: shared roots, and words that are another word's ancestor
            let meets = Set(nodes.values.filter { $0.role == .meeting }.map(\.id))
                .union(words.filter { w in sceneWords.contains { $0 != w && above[$0]!.contains(w) } })
            var below: [Int: Set<Int>] = [:]
            for m in meets { below[m] = closure(from: m, down) }
            for w in sceneWords {
                for m in meets where m != w && above[w]!.contains(m) {
                    keep.formUnion(above[w]!.intersection(below[m]!))  // the path from w to m
                }
            }
        }
        var meaningEdges = Set<XEdge>()
        if scope.keepsMeanings {
            meaningEdges = edges.filter(\.isMeaning)
            for e in meaningEdges { keep.formUnion([e.a, e.b]) }
        }
        if let picked, nodes[picked] != nil { keep.insert(picked) }
        nodes = nodes.filter { keep.contains($0.key) }
        edges = edges.filter { e in
            guard nodes[e.a] != nil, nodes[e.b] != nil else { return false }
            return e.isMeaning ? meaningEdges.contains(e) : scope.keepsRoots
        }
        sceneWords = sceneWords.filter { nodes[$0] != nil }
    }

    /// Thin out the steps between words and roots: a step is "in the middle" when it is a
    /// plain ancestor on a single line (one parent, one child). Along each run of such steps,
    /// the `keep` nearest the word stay; the rest become one shortcut edge to what is above.
    /// Words, shared roots, the tops of trees and branching points always stay.
    private func skipMiddleSteps(keeping keep: Int, besides picked: Int? = nil) {
        var parents: [Int: [XEdge]] = [:], children: [Int: [XEdge]] = [:]
        for e in edges where !e.isMeaning {
            parents[e.a, default: []].append(e)
            children[e.b, default: []].append(e)
        }
        func isMiddle(_ id: Int) -> Bool {
            guard id != picked, let n = nodes[id], n.role == .ancestor else { return false }
            return parents[id]?.count == 1 && children[id]?.count == 1
        }
        var dropped = Set<Int>()
        var shortcuts: [XEdge] = []
        for (id, _) in nodes where !isMiddle(id) {
            for up in parents[id] ?? [] where isMiddle(up.b) {
                // walk the run of middle steps above this node to the next node that stays
                var run: [Int] = []
                var edge = up
                while isMiddle(edge.b) {
                    run.append(edge.b)
                    edge = parents[edge.b]![0]
                }
                let top = edge.b
                let kept = run.prefix(keep)
                let skipped = run.dropFirst(keep)
                guard !skipped.isEmpty else { continue }
                dropped.formUnion(skipped)
                shortcuts.append(XEdge(a: kept.last ?? id, b: top, kind: "skip", meaning: nil,
                                       skipped: skipped.count))
            }
        }
        guard !dropped.isEmpty else { return }
        for id in dropped { nodes[id] = nil }
        edges = edges.filter { !dropped.contains($0.a) && !dropped.contains($0.b) }
        edges.formUnion(shortcuts)
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

    /// Highest level a node is raised to. Loops in the data (a word given as its own
    /// ancestor's ancestor) would otherwise push their nodes up without end.
    static let maxLevel = 14

    /// Every parent sits above all of its children: older words higher up.
    private func relevel() {
        for _ in 0..<64 {
            var changed = false
            for e in edges where !e.isMeaning {
                guard let child = nodes[e.a], let parent = nodes[e.b] else { continue }
                if parent.level <= child.level, child.level < Self.maxLevel {
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
