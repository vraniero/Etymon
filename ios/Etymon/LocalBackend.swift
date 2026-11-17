import Foundation
import SQLite3

/// The backend, on the phone: the same questions answered from the dictionary on the
/// device, in the same JSON the server sends, so every screen works without a server.
///
/// A port of backend/app.py (scenes, words, neighbors), backend/chain.py (Root Chain),
/// backend/games.py (the other games) and pipeline/connect.py + query.py (the search).
/// Kept close to the Python, function by function, so the two give the same answers: when
/// one changes, change the other.
///
/// The dictionary is `GraphStore.defaultURL`: the mobile graph (pipeline/export_mobile.py),
/// copied there in development, or built there from the language packs.
actor LocalBackend {
    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    /// The dictionary on this phone, if there is one. Looked for once, at first use.
    static let shared: LocalBackend? = {
        let url = GraphStore.defaultURL
        guard FileManager.default.fileExists(atPath: url.path),
              let backend = try? LocalBackend(url: url) else { return nil }
        return backend
    }()

    private let db: LocalDatabase

    init(url: URL) throws {
        db = try LocalDatabase(url: url)
        guard db.hasTable("term") else {
            throw Failure(status: 503, message: "The dictionary on this phone is empty.")
        }
    }

    // MARK: routing (APIClient's requests, answered here)

    func handle(method: String, path: String, query: [String: String], body: Data?) throws -> Data {
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let seed = query["seed"].flatMap(UInt64.init)
        let out: Any
        switch (method, path) {
        case ("POST", "scene"): out = try scene(json)
        case ("GET", "word"): out = try word(text: query["text"] ?? "", lang: query["lang"])
        case ("GET", "neighbors"):
            out = try neighbors(id: Int(query["id"] ?? "") ?? -1,
                                children: min(max(Int(query["children"] ?? "") ?? 16, 0), 60))
        case ("POST", "chain/reply"): out = try chainReply(json)
        case ("GET", "chain/start"): out = try chainStart(lang: query["lang"] ?? "", seed: seed)
        case ("GET", "games/impostor"): out = try impostor(lang: query["lang"], seed: seed)
        case ("GET", "games/root"): out = try gameRoot(lang: query["lang"], seed: seed)
        case ("GET", "games/birthplace"): out = try birthplace(lang: query["lang"], seed: seed)
        case ("POST", "games/check"): out = try check(json)
        default: throw Failure(status: 404, message: "no such question: \(path)")
        }
        return try JSONSerialization.data(withJSONObject: out)
    }

    // MARK: the search (pipeline/connect.py)

    static let cost: [String: Double] = ["inherited": 1.0, "borrowed": 1.0, "learned": 1.0,
                                         "calque": 1.2, "semantic_loan": 1.5, "derived": 1.0,
                                         "component": 1.0, "root": 6.0]
    static let inferredPenalty = 0.5
    static let maxCost = 16.0
    static let topLanguages: Set<String> = ["ine-pro"]
    static let lineageOrder = ["inherited", "derived", "learned", "borrowed", "calque",
                               "semantic_loan", "component"]
    /// The present-day languages, in pipeline/modern.py's order (ties go to the first).
    static let modern = ["en", "it", "es", "fr", "de", "ru", "uk", "be", "bg", "mk",
                         "sh", "pl", "cs", "sk", "sl", "ro", "hu", "et", "lt", "lv"]
    static let modernSet = Set(modern)

    struct Reach {
        let cost: Double
        let parent: Int?
        let kind: String?
    }
    typealias Tree = [Int: Reach]

    static func isAffix(_ word: String) -> Bool {
        if word.hasPrefix("*") { return word.dropFirst().hasPrefix("-") }
        return word.hasPrefix("-") || word.hasSuffix("-")
    }

    private lazy var openAffixes: Set<Int> = db.hasTable("open_affix")
        ? Set(db.rows("SELECT id FROM open_affix") { $0.int(0) }) : []

    private func closed(_ node: Int, _ word: String) -> Bool {
        Self.isAffix(word) && !openAffixes.contains(node)
    }

    private static let climbSQL = "SELECT e.dst, e.kind, e.inferred, d.word, d.lang FROM edge e "
        + "JOIN term d ON d.id=e.dst WHERE e.src=? AND e.kind IN ("
        + cost.keys.sorted().map { "'\($0)'" }.joined(separator: ",") + ")"

    /// Dijkstra up the source edges from the start ids, no further than maxCost.
    func climb(_ starts: [Int], _ maxCost: Double = LocalBackend.maxCost) -> Tree {
        var best: Tree = [:]
        var heap = MinHeap()
        for s in starts {
            best[s] = Reach(cost: 0, parent: nil, kind: nil)
            heap.push(0, s)
        }
        var top = Set<Int>()  // Proto-Indo-European: climbed only to what they're built from
        while let (cost, t) = heap.pop() {
            if cost > best[t]!.cost { continue }
            let rows = db.rows(Self.climbSQL, [t]) {
                ($0.int(0), $0.text(1), $0.int(2), $0.text(3), $0.text(4))
            }
            for (dst, kind, inferred, word, lang) in rows {
                if closed(dst, word) { continue }
                if top.contains(t) && kind != "component" { continue }
                let c = cost + Self.cost[kind]! + Self.inferredPenalty * Double(inferred)
                if c > maxCost { continue }
                if best[dst] == nil || c < best[dst]!.cost {
                    best[dst] = Reach(cost: c, parent: t, kind: kind)
                    heap.push(c, dst)
                }
                if Self.topLanguages.contains(lang) { top.insert(dst) }
            }
        }
        return best
    }

    /// (node, kind) from the start word up to `node`.
    static func path(_ tree: Tree, _ node: Int) -> [(Int, String?)] {
        var out: [(Int, String?)] = []
        var current: Int? = node
        while let n = current, let reach = tree[n] {
            out.append((n, reach.kind))
            current = reach.parent
        }
        return out.reversed()
    }

    private static let lineageSQL = "SELECT e.dst, e.kind, d.word FROM edge e JOIN term d ON d.id=e.dst "
        + "WHERE e.src=? AND e.kind IN (" + lineageOrder.map { "'\($0)'" }.joined(separator: ",")
        + ") ORDER BY e.inferred, instr('" + lineageOrder.joined(separator: " ") + "', e.kind)"

    /// The chain above a node, following the most direct link at each step, then the
    /// roots stated on any word of it.
    func lineage(_ start: Int, depth: Int = 12) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var seen: Set<Int> = [start]
        var seenOrder = [start]
        var node = start
        for _ in 0..<depth {
            let rows = db.rows(Self.lineageSQL, [node]) { ($0.int(0), $0.text(1), $0.text(2)) }
            guard let row = rows.first(where: { !seen.contains($0.0) && !closed($0.0, $0.2) }) else { break }
            node = row.0
            seen.insert(node)
            seenOrder.append(node)
            out.append((node, row.1))
        }
        let roots = db.rows("SELECT DISTINCT dst FROM edge WHERE kind='root' AND src IN ("
                            + Self.list(seenOrder) + ")", cached: false) { $0.int(0) }
        out += roots.filter { !seen.contains($0) }.map { ($0, "root") }
        return out
    }

    private static let parentsSQL = "SELECT e.dst, e.kind, e.inferred, d.word, d.lang FROM edge e "
        + "JOIN term d ON d.id=e.dst WHERE e.src=? AND e.kind IN ("
        + lineageOrder.map { "'\($0)'" }.joined(separator: ",")
        + ") ORDER BY e.inferred, instr('" + lineageOrder.joined(separator: " ") + "', e.kind)"

    /// Every ancestor above a node, a branch per part of a compound: (node, kind, child).
    func ancestry(_ node: Int, depth: Int = 12, limit: Int = 40) -> [(Int, String, Int)] {
        var out: [(Int, String, Int)] = []
        var seen: Set<Int> = [node]
        var linked = Set<[Int]>()

        func parents(_ n: Int, _ top: Bool) -> [(Int, String, String)] {
            var rows = db.rows(Self.parentsSQL, [n]) {
                ($0.int(0), $0.text(1), $0.int(2), $0.text(3), $0.text(4))
            }
            rows = rows.filter { $0.0 != n && !closed($0.0, $0.3) && (!top || $0.1 == "component") }
            guard let first = rows.first else { return [] }
            let parts = rows.dropFirst().filter { $0.1 == "component" && $0.2 == 0 && $0.0 != first.0 }
            return ([first] + parts).map { ($0.0, $0.1, $0.4) }
        }

        func walk(_ n: Int, _ top: Bool, _ left: Int, _ stack: Set<Int>) {
            for (dst, kind, lang) in parents(n, top) {
                if out.count >= limit { return }
                if stack.contains(dst) || linked.contains([n, dst]) { continue }
                linked.insert([n, dst])
                out.append((dst, kind, n))
                if !seen.contains(dst) {
                    seen.insert(dst)
                    if left > 1 { walk(dst, Self.topLanguages.contains(lang), left - 1, stack.union([dst])) }
                }
            }
        }

        let startLang = db.rows("SELECT lang FROM term WHERE id=?", [node]) { $0.text(0) }.first
        walk(node, startLang.map(Self.topLanguages.contains) ?? false, depth, [node])
        for n in [node] + out.map(\.0) {
            for r in db.rows("SELECT DISTINCT dst FROM edge WHERE kind='root' AND src=?", [n], { $0.int(0) })
            where !seen.contains(r) && out.count < limit + 4 {
                seen.insert(r)
                out.append((r, "root", n))
            }
        }
        return out
    }

    struct Meeting {
        let total: Double
        let node: Int
        let pathA: [(Int, String?)]
        let pathB: [(Int, String?)]
    }

    /// Nearest shared ancestors of two climbed trees, none above another one chosen.
    static func meetings(_ upA: Tree, _ upB: Tree, limit: Int = 3) -> [Meeting] {
        let shared = upA.keys.filter { upB[$0] != nil }
            .map { (upA[$0]!.cost + upB[$0]!.cost, $0) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var chosen: [(Double, Int)] = []
        for (total, n) in shared {
            let above = chosen.contains { _, m in
                let onPaths = Set(path(upA, m).map(\.0)).union(path(upB, m).map(\.0))
                return onPaths.contains(n) || path(upA, n).contains { $0.0 == m }
            }
            if above { continue }
            chosen.append((total, n))
            if chosen.count == limit { break }
        }
        return chosen.map { Meeting(total: $0.0, node: $0.1, pathA: path(upA, $0.1), pathB: path(upB, $0.1)) }
    }

    // MARK: words (pipeline/query.py, backend/app.py)

    static let punctuation = Set(" \t\n.,;:!?¡¿\"'“”‘’«»()[]{}")

    static func normalize(_ text: String) -> String {
        String(text.drop { punctuation.contains($0) }.reversed().drop { punctuation.contains($0) }.reversed())
    }

    /// Term ids for a surface word: itself if it has its own etymology, else the lemmas it
    /// is a form of (padri -> padre), plus its bare entry.
    func resolve(_ lang: String, _ word: String) -> [Int] {
        let own = db.rows("SELECT id FROM term t WHERE lang=? AND word=? AND has_entry=1 AND "
                          + "EXISTS (SELECT 1 FROM edge WHERE src=t.id)", [lang, word]) { $0.int(0) }
        if !own.isEmpty { return own }
        var rows = db.rows("SELECT lemma FROM form WHERE lang=? AND form=?", [lang, word]) { $0.int(0) }
        if rows.isEmpty {
            rows = db.rows("SELECT id FROM term WHERE lang=? AND word=? AND has_entry=1", [lang, word]) { $0.int(0) }
        }
        if rows.isEmpty && word != word.lowercased() { return resolve(lang, word.lowercased()) }
        return Self.unique(rows)
    }

    private struct Found {
        let ids: [Int]
        let zipf: Double
        let hasEdges: Bool
    }

    private func candidates(_ text: String) -> [(String, Found)] {
        Self.modern.compactMap { code in
            let ids = resolve(code, text)
            guard !ids.isEmpty else { return nil }
            let zipf = ids.map { db.rows("SELECT coalesce(zipf, 0) FROM term WHERE id=?", [$0]) { $0.double(0) }.first ?? 0 }.max() ?? 0
            let hasEdges = !db.rows("SELECT 1 FROM edge WHERE src IN (" + Self.list(ids) + ") LIMIT 1",
                                    cached: false) { _ in true }.isEmpty
            return (code, Found(ids: ids, zipf: zipf, hasEdges: hasEdges))
        }
    }

    static let hintMargin = 1.0

    /// The language a word is read in, and its terms.
    func bestLanguage(_ text: String, _ lang: String?, hint: String? = nil) -> (String?, [Int]) {
        if let lang, !lang.isEmpty { return (lang, resolve(lang, text)) }
        let found = candidates(text)
        guard !found.isEmpty else { return (nil, []) }
        var best = found[0]
        for f in found.dropFirst() where (f.1.hasEdges ? 1 : 0, f.1.zipf) > (best.1.hasEdges ? 1 : 0, best.1.zipf) {
            best = f
        }
        if let hint, let hinted = found.first(where: { $0.0 == hint }) {
            let en = found.first { $0.0 == "en" }
            if hint != "en", let en, en.1.hasEdges, en.1.zipf >= hinted.1.zipf + Self.hintMargin {
                best = en
            } else {
                best = hinted
            }
        }
        return (best.0, best.1.ids)
    }

    /// The share of these words the dictionary has in a language (0…1): how a transcript
    /// in the right language stands out from the same speech heard as another one.
    func knownShare(of words: [String], in lang: String) -> Double {
        guard !words.isEmpty else { return 0 }
        return Double(words.filter { !resolve(lang, $0).isEmpty }.count) / Double(words.count)
    }

    func meanings(_ ids: [Int]) -> [String] {
        guard !ids.isEmpty, db.hasTable("meaning") else { return [] }
        return db.rows("SELECT DISTINCT key FROM meaning WHERE term IN (" + Self.list(ids) + ") ORDER BY rowid",
                       cached: false) { $0.text(0) }
    }

    private lazy var hasGeo = db.hasTable("language_geo")

    /// {"id": node} for the app, keyed by id as text (JSON object keys).
    func nodes<S: Sequence>(_ ids: S) -> [String: [String: Any]] where S.Element == Int {
        let all = Array(Set(ids))
        guard !all.isEmpty else { return [:] }
        let sql = "SELECT t.id, t.lang, coalesce(l.name, t.lang), t.word, t.gloss, "
            + (hasGeo ? "g.lat, g.lon" : "NULL, NULL") + " FROM term t "
            + "LEFT JOIN language l ON l.code=t.lang "
            + (hasGeo ? "LEFT JOIN language_geo g ON g.code=t.lang " : "")
            + "WHERE t.id IN (" + Self.list(all) + ")"
        var out: [String: [String: Any]] = [:]
        for node in db.rows(sql, [], cached: false, { row -> [String: Any] in
            let word = row.text(3)
            return ["id": row.int(0), "lang": row.text(1), "language": row.text(2), "word": word,
                    "gloss": row.optionalText(4) ?? NSNull(), "reconstructed": word.hasPrefix("*"),
                    "lat": row.optionalDouble(5) ?? NSNull(), "lon": row.optionalDouble(6) ?? NSNull()]
        }) {
            out[String(node["id"] as! Int)] = node
        }
        return out
    }

    static func steps(_ path: [(Int, String?)]) -> [[String: Any]] {
        path.map { ["node": $0.0, "kind": $0.1 ?? NSNull()] }
    }

    static func tree(_ ancestry: [(Int, String, Int)]) -> [[String: Any]] {
        ancestry.map { ["node": $0.0, "kind": $0.1, "from": $0.2] }
    }

    // MARK: POST /scene

    static let autoDepths: [Double] = [16, 24, 32, 40]

    private struct SceneWord {
        let text: String
        let lang: String?
        let terms: [Int]
        let meanings: [String]
    }

    func scene(_ body: [String: Any]) throws -> [String: Any] {
        let input = body["words"] as? [[String: Any]] ?? []
        guard input.count <= 500 else { throw Failure(status: 422, message: "too many words") }
        let hint = body["lang"] as? String
        let perPair = (body["connections_per_pair"] as? Int) ?? 1
        let maxCost = (body["max_cost"] as? NSNumber)?.doubleValue

        var words: [SceneWord] = []
        var seen = Set<String>()
        for w in input {
            let text = Self.normalize(w["text"] as? String ?? "")
            let given = w["lang"] as? String
            let key = text.lowercased() + "\u{1}" + (given ?? "\u{0}")
            if text.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            let (lang, ids) = bestLanguage(text, given, hint: hint)
            words.append(SceneWord(text: text, lang: lang, terms: ids, meanings: meanings(ids)))
        }

        var climbed: [String: Tree] = [:]
        func treeAt(_ i: Int, _ depth: Double) -> Tree {
            let key = "\(i)|\(depth)"
            if let tree = climbed[key] { return tree }
            let tree = words[i].terms.isEmpty ? [:] : climb(words[i].terms, depth)
            climbed[key] = tree
            return tree
        }

        var connections: [[String: Any]] = []
        var sameWord: [[String: Any]] = []
        var used = Set<Int>()
        var above: [Int: [(Int, String, Int)]] = [:]
        var linked = Set<Int>()

        func connect(_ i: Int, _ j: Int, _ depth: Double) {
            let ta = treeAt(i, depth), tb = treeAt(j, depth)
            guard !ta.isEmpty, !tb.isEmpty else { return }
            for m in Self.meetings(ta, tb, limit: perPair) {
                if above[m.node] == nil { above[m.node] = ancestry(m.node) }
                let deeper = above[m.node]!
                connections.append(["a": i, "b": j, "meet": m.node, "distance": m.total,
                                     "depth": max(ta[m.node]!.cost, tb[m.node]!.cost),
                                     "path_a": Self.steps(m.pathA), "path_b": Self.steps(m.pathB),
                                     "deeper": Self.tree(deeper)])
                used.formUnion((m.pathA + m.pathB).map(\.0))
                used.formUnion(deeper.map(\.0))
                linked.formUnion([i, j])
            }
        }

        let depths = maxCost.map { [$0] } ?? Self.autoDepths
        var pairs: [(Int, Int)] = []
        for i in words.indices {
            for j in words.indices where j > i {
                if let shared = words[i].terms.first(where: { words[j].terms.contains($0) }) {
                    sameWord.append(["a": i, "b": j, "lemma": shared])
                    linked.formUnion([i, j])
                } else {
                    pairs.append((i, j))
                }
            }
        }
        var searched = depths[0]
        for (i, j) in pairs { connect(i, j, searched) }
        for depth in depths.dropFirst() {
            let loose = Set(words.indices.filter { !words[$0].terms.isEmpty && !linked.contains($0) })
            let todo = pairs.filter { loose.contains($0.0) || loose.contains($0.1) }
            let involved = Set(todo.flatMap { [$0.0, $0.1] })
            if !involved.contains(where: { treeAt($0, depth).count > treeAt($0, searched).count }) { break }
            for (i, j) in todo { connect(i, j, depth) }
            searched = depth
        }
        let sorted = connections.enumerated().sorted {
            let (a, b) = ($0.element["distance"] as! Double, $1.element["distance"] as! Double)
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        used.formUnion(words.flatMap(\.terms))

        var semantic: [[String: Any]] = []
        for i in words.indices {
            for j in words.indices where j > i {
                let (a, b) = (words[i], words[j])
                if a.meanings.isEmpty || b.meanings.isEmpty || a.lang == b.lang { continue }
                if let shared = a.meanings.first(where: b.meanings.contains) {
                    semantic.append(["a": i, "b": j, "meaning": shared])
                }
            }
        }
        let reached = climbed.values.flatMap { $0.values.map(\.cost) }.max() ?? 0
        let deepest = sorted.map { $0["depth"] as! Double }.max() ?? 0
        return [
            "search": ["max_cost": searched, "auto": maxCost == nil, "reached": reached, "depth": deepest],
            "words": words.map { ["text": $0.text, "lang": $0.lang ?? NSNull(), "terms": $0.terms,
                                  "meanings": $0.meanings] as [String: Any] },
            "connections": sorted, "semantic": semantic, "same_word": sameWord,
            "nodes": nodes(used),
        ]
    }

    // MARK: GET /word, /neighbors

    func word(text: String, lang: String?) throws -> [String: Any] {
        let (lang, ids) = bestLanguage(Self.normalize(text), lang)
        guard !ids.isEmpty else { throw Failure(status: 404, message: "word not found") }
        var entries: [[String: Any]] = []
        var used = Set(ids)
        for tid in ids {
            let line = ancestry(tid)
            used.formUnion(line.map(\.0))
            entries.append(["term": tid, "lineage": Self.tree(line)])
        }
        return ["text": text, "lang": lang ?? NSNull(), "meanings": meanings(ids),
                "entries": entries, "nodes": nodes(used)]
    }

    static let descent = ["inherited", "borrowed", "learned", "calque", "semantic_loan",
                          "derived", "component", "root"]
    private static let descentList = descent.map { "'\($0)'" }.joined(separator: ",")
    private static let modernList = modern.map { "'\($0)'" }.joined(separator: ",")

    func neighbors(id: Int, children: Int) throws -> [String: Any] {
        guard !db.rows("SELECT 1 FROM term WHERE id=?", [id], { _ in true }).isEmpty else {
            throw Failure(status: 404, message: "node not found")
        }
        let parents = db.rows(
            "SELECT e.dst, e.kind, t.word FROM edge e JOIN term t ON t.id=e.dst "
            + "WHERE e.src=? AND e.kind IN (\(Self.descentList)) ORDER BY e.inferred, "
            + "instr('inherited borrowed learned calque semantic_loan derived component root', e.kind)",
            [id]) { ($0.int(0), $0.text(1), $0.text(2)) }
            .filter { !closed($0.0, $0.2) }.prefix(10)
        let kids = db.rows(
            "SELECT e.src, e.kind, t.word FROM edge e JOIN term t ON t.id=e.src "
            + "WHERE e.dst=? AND e.kind IN (\(Self.descentList)) "
            + "ORDER BY (t.lang IN (\(Self.modernList))) DESC, coalesce(t.zipf, 0) DESC, t.has_entry DESC, e.inferred "
            + "LIMIT ?", [id, children * 3]) { ($0.int(0), $0.text(1), $0.text(2)) }
            .filter { !closed($0.0, $0.2) }.prefix(children)
        let used = [id] + parents.map(\.0) + kids.map(\.0)
        let total = db.rows("SELECT count(*) FROM edge WHERE dst=? AND kind IN (\(Self.descentList))", [id]) { $0.int(0) }.first ?? 0
        return ["node": id,
                "parents": parents.map { ["node": $0.0, "kind": $0.1] },
                "children": kids.map { ["node": $0.0, "kind": $0.1] },
                "total_children": total, "meanings": meanings([id]), "nodes": nodes(used)]
    }

    // MARK: Root Chain (backend/chain.py)

    struct Level {
        var climb: Double
        var minZipf: Double
        var anyLanguage: Bool
        var maxDistance: Double
        var ancestors = 12
        var generations: Int? = nil
    }

    static let levels: [String: Level] = [
        "easy": Level(climb: 8, minZipf: 3.5, anyLanguage: false, maxDistance: 6),
        "normal": Level(climb: 12, minZipf: 2.5, anyLanguage: false, maxDistance: 9),
        "hard": Level(climb: 16, minZipf: 1.0, anyLanguage: true, maxDistance: 14),
    ]
    static func wider(_ level: Level) -> Level {
        var l = level
        l.climb = 20; l.minZipf = 0; l.maxDistance = 20; l.ancestors = 24; l.generations = 5
        return l
    }
    static let childrenPerAncestor = 40
    static let descentGenerations = 3
    static let poolEnough = 300
    static let candidatesChecked = 30

    /// Modern words below an ancestor, in the order found: ids, and each one's word.
    struct Below {
        var order: [Int] = []
        var words: [Int: (word: String, lang: String, zipf: Double)] = [:]
        mutating func add(_ other: Below) {
            for id in other.order where words[id] == nil {
                order.append(id)
                words[id] = other.words[id]
            }
        }
    }

    private static let descendSQL = "SELECT t.id, t.word, t.lang, coalesce(t.zipf, 0), t.has_entry "
        + "FROM edge e JOIN term t ON t.id=e.src WHERE e.dst=? AND e.kind IN (\(descentList)) "
        + "ORDER BY (t.lang IN (\(modernList))) DESC, coalesce(t.zipf, 0) DESC LIMIT \(childrenPerAncestor)"

    func descend(_ ancestor: Int, seen: inout Set<Int>, generations: Int? = nil,
                 keep: (String, String, Double) -> Bool) -> Below {
        var found = Below()
        var frontier = [ancestor]
        for _ in 0..<(generations ?? Self.descentGenerations) {
            var below: [Int] = []
            for parent in frontier {
                let rows = db.rows(Self.descendSQL, [parent]) {
                    ($0.int(0), $0.text(1), $0.text(2), $0.double(3), $0.int(4))
                }
                for (src, word, wlang, zipf, entry) in rows {
                    if seen.contains(src) { continue }
                    seen.insert(src)
                    below.append(src)
                    if Self.modernSet.contains(wlang) && entry != 0 && Self.plain(word) {
                        let z = frequency(src, wlang, zipf)
                        if keep(word, wlang, z) {
                            found.order.append(src)
                            found.words[src] = (word, wlang, z)
                        }
                    }
                }
            }
            frontier = below
        }
        return found
    }

    /// A word a player could type: no phrases, affixes, abbreviations, reconstructions or
    /// proper nouns.
    static func plain(_ word: String) -> Bool {
        !word.contains(" ") && !word.contains("-") && !word.hasPrefix("*") && word.count > 1
            && !word.contains(where: \.isNumber) && word != word.uppercased()
            && !(word.first?.isUppercase ?? false)
    }

    static func script(_ word: String) -> String {
        word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? "cyrl" : "latn"
    }

    func chainReply(_ body: [String: Any]) throws -> [String: Any] {
        guard let level = Self.levels[body["level"] as? String ?? "normal"] else {
            throw Failure(status: 422, message: "unknown level")
        }
        let levelName = body["level"] as? String ?? "normal"
        var rng = GameRandom(seed: (body["seed"] as? NSNumber)?.uint64Value)
        let wordIn = body["word"] as? [String: Any] ?? [:]
        let text = wordIn["text"] as? String ?? ""
        let (lang, ids) = bestLanguage(Self.normalize(text), wordIn["lang"] as? String)
        guard !ids.isEmpty else { throw Failure(status: 404, message: "word not found") }
        let used = Set((body["used"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            .union([text.trimmingCharacters(in: .whitespaces).lowercased()])
        let gameLang = body["lang"] as? String
        let langs: Set<String>? = gameLang.map { [$0] } ?? (level.anyLanguage ? nil : [lang ?? "", "en"])
        let avoid = (body["avoid_root"] as? NSNumber)?.intValue
        let near = climb(ids, Self.maxCost)
        var pool = Below()
        var checked: [(Double, Int, Int)] = []
        var settings = level
        for wide in [false, true] {
            settings = wide ? Self.wider(level) : level
            pool = chainCandidates(ids, text: text, avoid: avoid, level: settings, used: used, langs: langs)
            checked = verified(ids, avoid: avoid, pool: pool, near: near, rng: &rng)
            if !checked.isEmpty { break }
        }
        guard !checked.isEmpty else { throw Failure(status: 404, message: "no word left to play") }
        checked.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2) }
        let close = checked.filter { $0.0 <= settings.maxDistance }
        let options = close.isEmpty ? [checked[0]] : close
        let pick = levelName == "easy" ? options[0] : options.randomElement(using: &rng)!
        let chosen = pool.words[pick.1]!
        return ["text": chosen.word, "lang": chosen.lang, "meet": pick.2, "candidates": pool.order.count]
    }

    private func chainCandidates(_ ids: [Int], text: String, avoid: Int?, level: Level,
                                 used: Set<String>, langs: Set<String>?) -> Below {
        let up = climb(ids, level.climb)
        let ancestors = Self.byCost(up, except: Set(ids).union(avoid.map { [$0] } ?? []))
            .prefix(level.ancestors)
        var pool = Below()
        var seen = Set(ids).union(ancestors.map { $0.1 })
        let mine = Self.script(text)
        for (_, anc) in ancestors {
            pool.add(descend(anc, seen: &seen, generations: level.generations) { word, wlang, zipf in
                !used.contains(word.lowercased()) && zipf >= level.minZipf
                    && (langs == nil || langs!.contains(wlang)) && Self.script(word) == mine
            })
            if pool.order.count >= Self.poolEnough { break }
        }
        return pool
    }

    private func verified(_ ids: [Int], avoid: Int?, pool: Below, near: Tree,
                          rng: inout GameRandom) -> [(Double, Int, Int)] {
        var ranked = Array(pool.order.enumerated().sorted {
            let (a, b) = (pool.words[$0.element]!.zipf, pool.words[$1.element]!.zipf)
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element).prefix(Self.candidatesChecked * 2))
        ranked.shuffle(using: &rng)
        var checked: [(Double, Int, Int)] = []
        for tid in ranked.prefix(Self.candidatesChecked) {
            let w = pool.words[tid]!
            if !Set(resolve(w.lang, w.word)).isDisjoint(with: ids) { continue }
            if let found = Self.meetings(near, climb([tid], Self.maxCost), limit: 1).first,
               found.node != avoid, sensibleMeet(found.node) {
                checked.append((found.total, tid, found.node))
            }
        }
        return checked
    }

    private func sensibleMeet(_ node: Int) -> Bool {
        guard let word = wordOf(node) else { return false }
        return word.trimmingCharacters(in: CharacterSet(charactersIn: "*-")).count > 1
    }

    private func wordOf(_ id: Int) -> String? {
        db.rows("SELECT word FROM term WHERE id=?", [id]) { $0.text(0) }.first
    }

    static let startZipf = (4.0, 5.6)
    static let startAncestors = 3

    func chainStart(lang: String, seed: UInt64?) throws -> [String: Any] {
        guard Self.modernSet.contains(lang) else { throw Failure(status: 404, message: "unknown language") }
        var rng = GameRandom(seed: seed)
        var rows = commonWords(lang)
        rows.shuffle(using: &rng)
        for (tid, word) in rows.prefix(60)
        where Self.plain(word) && word.count > 2 && climb([tid], Self.maxCost).count > Self.startAncestors {
            return ["text": word, "lang": lang]
        }
        throw Failure(status: 404, message: "no opening word")
    }

    private var common: [String: [(Int, String)]] = [:]

    /// (id, word) of a language's common words with an etymology; read once.
    func commonWords(_ lang: String) -> [(Int, String)] {
        if let rows = common[lang] { return rows }
        let (low, high) = Self.startZipf
        let rows: [(Int, String)]
        if let estimated = estimates(lang) {
            let ids = estimated.filter { low <= $0.value && $0.value <= high }.map(\.key)
            rows = ids.isEmpty ? [] : db.rows(
                "SELECT t.id, t.word FROM term t WHERE t.id IN (" + Self.list(ids) + ") "
                + "AND t.has_entry=1 AND EXISTS (SELECT 1 FROM edge e WHERE e.src=t.id)",
                cached: false) { ($0.int(0), $0.text(1)) }
        } else {
            rows = db.rows("SELECT t.id, t.word FROM term t WHERE t.lang=? AND t.has_entry=1 "
                           + "AND t.zipf BETWEEN ? AND ? AND EXISTS (SELECT 1 FROM edge e WHERE e.src=t.id)",
                           [lang, low, high]) { ($0.int(0), $0.text(1)) }
        }
        common[lang] = rows
        return rows
    }

    private var estimated: [String: [Int: Double]] = [:]
    private var hasFrequencies = Set<String>()

    /// For a language without a frequency list: each word's frequency guessed from its
    /// English meaning. Nil for a language with real frequencies.
    func estimates(_ lang: String) -> [Int: Double]? {
        if hasFrequencies.contains(lang) { return nil }
        if let guess = estimated[lang] { return guess }
        if !db.rows("SELECT 1 FROM term WHERE lang=? AND zipf IS NOT NULL LIMIT 1", [lang], { _ in true }).isEmpty {
            hasFrequencies.insert(lang)
            return nil
        }
        let meanings = db.rows("SELECT term, key FROM meaning WHERE term IN (SELECT id FROM term WHERE lang=?)",
                               [lang]) { ($0.int(0), $0.text(1)) }
        let keys = Array(Set(meanings.map(\.1)))
        var english: [String: Double] = [:]
        for start in stride(from: 0, to: keys.count, by: 500) {
            let part = Array(keys[start..<min(start + 500, keys.count)])
            for (word, zipf) in db.rows("SELECT word, zipf FROM term WHERE lang='en' AND zipf IS NOT NULL "
                                        + "AND word IN (" + Array(repeating: "?", count: part.count).joined(separator: ",") + ")",
                                        part, cached: false, { ($0.text(0), $0.double(1)) }) {
                english[word] = zipf
            }
        }
        var guess: [Int: Double] = [:]
        for (term, key) in meanings {
            if let z = english[key] { guess[term] = max(guess[term] ?? 0, z) }
        }
        estimated[lang] = guess
        return guess
    }

    func frequency(_ tid: Int, _ lang: String, _ zipf: Double) -> Double {
        guard let guess = estimates(lang) else { return zipf }
        return guess[tid] ?? 0
    }

    // MARK: the other games (backend/games.py)

    static let defaultLanguages = ["en", "it", "es", "fr", "de"]
    static let tries = 40
    static let checkDepth = 24.0

    private func gameLanguage(_ lang: String?, _ rng: inout GameRandom) throws -> String {
        guard let lang else { return Self.defaultLanguages.randomElement(using: &rng)! }
        guard Self.modernSet.contains(lang) else { throw Failure(status: 404, message: "unknown language") }
        return lang
    }

    private func asWord(_ id: Int, _ nodes: [String: [String: Any]]) -> [String: Any] {
        let n = nodes[String(id)] ?? self.nodes([id])[String(id)] ?? [:]
        return ["text": n["word"] ?? "", "lang": n["lang"] ?? "", "language": n["language"] ?? ""]
    }

    private func line(_ tree: Tree, _ start: Int, _ to: Int) -> [Int] {
        tree[to] != nil ? Self.path(tree, to).map(\.0) : [start]
    }

    func impostor(lang: String?, seed: UInt64?) throws -> [String: Any] {
        var rng = GameRandom(seed: seed)
        let lang = try gameLanguage(lang, &rng)
        var words = commonWords(lang)
        words.shuffle(using: &rng)
        for (tid, word) in words.prefix(Self.tries) {
            if !Self.plain(word) { continue }
            let up = climb([tid], 12)
            let ancestors = Self.byCost(up, except: [tid])
            for (cost, anc) in ancestors {
                if cost < 1 || cost > 9 { continue }
                guard let ancWord = wordOf(anc),
                      ancWord.trimmingCharacters(in: CharacterSet(charactersIn: "*-")).count >= 3 else { continue }
                var seen: Set<Int> = [tid]
                let below = descend(anc, seen: &seen) { w, l, z in
                    l == lang && z >= 2.5 && w.lowercased() != word.lowercased()
                        && Self.script(w) == Self.script(word)
                }
                let cousins = distinct(lang, [tid] + below.order, 3)
                if cousins.count < 3 { continue }
                var trees = Dictionary(uniqueKeysWithValues: cousins.map { ($0, climb([$0], Self.maxCost)) })
                guard let (fake, why) = disguise(lang, cousins, trees, &rng) else { break }
                var four = cousins + [fake]
                four.shuffle(using: &rng)
                trees[fake] = [fake: Reach(cost: 0, parent: nil, kind: nil)]
                let paths = four.map { c in
                    c != fake ? line(trees[c]!, c, anc) : [fake] + lineage(fake).map(\.0).prefix(4)
                }
                let nodes = self.nodes(Set(paths.flatMap { $0 }).union([anc]))
                return ["words": four.map { asWord($0, nodes) }, "impostor": four.firstIndex(of: fake)!,
                        "root": anc, "why": why, "paths": paths, "nodes": nodes]
            }
        }
        throw Failure(status: 404, message: "no puzzle found")
    }

    /// Up to n of the ids that are different words, not forms of one another nor alike.
    private func distinct(_ lang: String, _ ids: [Int], _ n: Int) -> [Int] {
        var out: [Int] = []
        var terms = Set<Int>()
        var starts = Set<String>()
        for t in ids {
            guard let word = wordOf(t) else { continue }
            let own = Set(resolve(lang, word)).union([t])
            let start = String(word.prefix(4)).lowercased()
            if !own.isDisjoint(with: terms) || starts.contains(start) { continue }
            terms.formUnion(own)
            starts.insert(start)
            out.append(t)
            if out.count == n { break }
        }
        return out
    }

    /// A word that looks like one of the cousins or means the same, sharing no ancestor.
    private func disguise(_ lang: String, _ cousins: [Int], _ trees: [Int: Tree],
                          _ rng: inout GameRandom) -> (Int, String)? {
        func unrelated(_ t: Int, _ word: String) -> Bool {
            if resolve(lang, word) != [t] { return false }
            let mine = climb([t], Self.maxCost)
            let older = !db.rows("SELECT 1 FROM term WHERE id IN (" + Self.list(Array(mine.keys)) + ") "
                                 + "AND lang NOT IN (\(Self.modernList)) LIMIT 1", cached: false) { _ in true }.isEmpty
            return older && trees.values.allSatisfy { Self.meetings(mine, $0, limit: 1).isEmpty }
        }
        for c in cousins.shuffled(using: &rng) {
            guard let word = wordOf(c) else { continue }
            for size in [4, 3] where word.count > size {
                let rows = db.rows("SELECT id, word, zipf FROM term WHERE lang=? AND word LIKE ? AND has_entry=1 "
                                   + "AND id != ? ORDER BY random() LIMIT 40",
                                   [lang, String(word.prefix(size)) + "%", c]) {
                    ($0.int(0), $0.text(1), $0.optionalDouble(2) ?? 0)
                }
                for (t, w, z) in rows where frequency(t, lang, z) >= 2.5 && Self.plain(w)
                    && !cousins.contains(t) && unrelated(t, w) {
                    return (t, "looks")
                }
            }
            let rows = db.rows("SELECT m2.term FROM meaning m1 JOIN meaning m2 ON m2.key=m1.key "
                               + "JOIN term t ON t.id=m2.term WHERE m1.term=? AND t.lang=? AND m2.term != ? "
                               + "AND t.has_entry=1 LIMIT 12", [c, lang, c]) { $0.int(0) }
            for t in rows {
                guard let w = wordOf(t) else { continue }
                if Self.plain(w) && Self.script(w) == Self.script(word) && !cousins.contains(t) && unrelated(t, w) {
                    return (t, "means")
                }
            }
        }
        return nil
    }

    static let minDescendants = 8

    func gameRoot(lang: String?, seed: UInt64?) throws -> [String: Any] {
        var rng = GameRandom(seed: seed)
        let lang = try gameLanguage(lang, &rng)
        var words = commonWords(lang)
        words.shuffle(using: &rng)
        for (tid, _) in words.prefix(Self.tries) {
            let up = climb([tid], 10)
            var older = up.filter { $0.value.cost >= 2 }.map(\.key).sorted()
            older.shuffle(using: &rng)
            for anc in older.prefix(4) {
                guard let node = nodes([anc])[String(anc)], let nodeLang = node["lang"] as? String,
                      let nodeWord = node["word"] as? String, !Self.modernSet.contains(nodeLang),
                      nodeWord.trimmingCharacters(in: CharacterSet(charactersIn: "*-")).count >= 3 else { continue }
                var seen = Set<Int>()
                let below = descend(anc, seen: &seen, generations: 4) { _, l, z in l == lang && z >= 2.0 }
                if below.order.count >= Self.minDescendants {
                    var examples = below.order.enumerated().sorted {
                        let (a, b) = (below.words[$0.element]!.zipf, below.words[$1.element]!.zipf)
                        return a != b ? a > b : $0.offset < $1.offset
                    }.map { below.words[$0.element]!.word }
                    let first = Self.script(examples[0])
                    examples = Self.unique(examples.filter { Self.script($0) == first })
                    return ["root": node, "lang": lang, "total": below.order.count,
                            "examples": Array(examples.prefix(12))]
                }
            }
        }
        throw Failure(status: 404, message: "no root found")
    }

    func check(_ body: [String: Any]) throws -> [String: Any] {
        guard let root = (body["root"] as? NSNumber)?.intValue else {
            throw Failure(status: 422, message: "no root")
        }
        var found: [[String: Any]] = []
        var unknown: [String] = []
        var used: Set<Int> = [root]
        for w in body["words"] as? [[String: Any]] ?? [] {
            let text = Self.normalize(w["text"] as? String ?? "")
            let (lang, ids) = bestLanguage(text, w["lang"] as? String)
            if ids.isEmpty {
                unknown.append(text)
                continue
            }
            let tree = climb(ids, Self.checkDepth)
            if tree[root] != nil {
                let way = Self.path(tree, root).map(\.0)
                used.formUnion(way)
                found.append(["text": text, "lang": lang ?? NSNull(), "path": way])
            }
        }
        return ["found": found, "unknown": unknown, "nodes": nodes(used)]
    }

    static let minTravelKm = 400.0

    static func km(_ a: [String: Any], _ b: [String: Any]) -> Double {
        guard let la1 = a["lat"] as? Double, let lo1 = a["lon"] as? Double,
              let la2 = b["lat"] as? Double, let lo2 = b["lon"] as? Double else { return 0 }
        let r = Double.pi / 180
        let h = pow(sin((la2 - la1) * r / 2), 2) + cos(la1 * r) * cos(la2 * r) * pow(sin((lo2 - lo1) * r / 2), 2)
        return 6371 * 2 * asin(h.squareRoot())
    }

    func birthplace(lang: String?, seed: UInt64?) throws -> [String: Any] {
        guard hasGeo else { throw Failure(status: 503, message: "no places in the dictionary") }
        var rng = GameRandom(seed: seed)
        let lang = try gameLanguage(lang, &rng)
        var words = commonWords(lang)
        words.shuffle(using: &rng)
        for (tid, word) in words.prefix(Self.tries * 3) {
            if !Self.plain(word) { continue }
            let steps = [tid] + lineage(tid).filter { $0.1 != "root" }.map(\.0)
            let nodes = self.nodes(steps)
            let placed = steps.filter { nodes[String($0)]?["lat"] is Double }
            let attested = placed.filter { !(nodes[String($0)]?["reconstructed"] as? Bool ?? true) }
            guard attested.count >= 2, let born = attested.last,
                  let bornNode = nodes[String(born)], let start = nodes[String(tid)] else { continue }
            if (bornNode["word"] as? String)?.lowercased() == word.lowercased() { continue }
            let distance = start["lat"] is Double ? Self.km(start, bornNode) : 0
            if distance < Self.minTravelKm { continue }
            let journey = Array(placed.prefix(through: placed.firstIndex(of: born)!))
            return ["word": asWord(tid, nodes), "born": born, "journey": journey, "km": distance,
                    "nodes": nodes]
        }
        throw Failure(status: 404, message: "no word found")
    }

    // MARK: helpers

    /// A climbed tree's nodes as (cost, id), nearest first, leaving some out.
    static func byCost(_ tree: Tree, except: Set<Int>) -> [(Double, Int)] {
        var out: [(Double, Int)] = []
        for (id, reach) in tree where !except.contains(id) { out.append((reach.cost, id)) }
        out.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
        return out
    }

    /// Integers as an SQL list: "1,2,3" (ids only, never text).
    static func list<S: Sequence>(_ ids: S) -> String where S.Element == Int {
        ids.map(String.init).joined(separator: ",")
    }

    static func unique<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// Smallest (cost, id) first, as Python's heapq orders its tuples.
struct MinHeap {
    private var items: [(Double, Int)] = []

    private static func less(_ a: (Double, Int), _ b: (Double, Int)) -> Bool {
        a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
    }

    mutating func push(_ cost: Double, _ id: Int) {
        items.append((cost, id))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard Self.less(items[i], items[parent]) else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < items.count && Self.less(items[l], items[smallest]) { smallest = l }
            if r < items.count && Self.less(items[r], items[smallest]) { smallest = r }
            if smallest == i { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return top
    }
}

/// A repeatable random sequence for a seed (SplitMix64); a fresh one without.
struct GameRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64?) {
        state = seed ?? UInt64.random(in: .min ... .max)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Read-only SQLite with prepared statements kept for reuse: the search asks the same few
/// questions thousands of times.
final class LocalDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var tables: Set<String> = []
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw LocalBackend.Failure(status: 503, message: "cannot open the dictionary")
        }
        sqlite3_exec(handle, "PRAGMA cache_size = -32000", nil, nil, nil)  // 32 MB of pages
        tables = Set(rows("SELECT name FROM sqlite_master WHERE type='table'") { $0.text(0) })
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    func hasTable(_ name: String) -> Bool { tables.contains(name) }

    struct Row {
        fileprivate let statement: OpaquePointer?
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        func text(_ i: Int32) -> String {
            sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
        }
        func optionalText(_ i: Int32) -> String? {
            sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : text(i)
        }
        func optionalDouble(_ i: Int32) -> Double? {
            sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : double(i)
        }
    }

    /// Every row of a query, read before returning (so a caller may query again inside).
    /// `cached`: keep the prepared statement for next time; off for SQL with ids written
    /// in (an IN list), which differs every time.
    func rows<T>(_ sql: String, _ args: [Any] = [], cached: Bool = true, _ read: (Row) -> T) -> [T] {
        guard let statement = prepare(sql, cached: cached) else { return [] }
        defer {
            if cached {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            } else {
                sqlite3_finalize(statement)
            }
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let v as Int: sqlite3_bind_int64(statement, index, sqlite3_int64(v))
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
            default: sqlite3_bind_null(statement, index)
            }
        }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(read(Row(statement: statement))) }
        return out
    }

    private func prepare(_ sql: String, cached: Bool) -> OpaquePointer? {
        if cached, let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            print("LocalDatabase: \(String(cString: sqlite3_errmsg(handle))) in \(sql)")
            sqlite3_finalize(statement)
            return nil
        }
        if cached { statements[sql] = statement }
        return statement
    }
}
