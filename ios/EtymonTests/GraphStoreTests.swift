import XCTest
@testable import Etymon

/// The dictionary on the phone is built from packs: merged in as they arrive, rebuilt when
/// one goes. Rows two packs share (an ancestor, a word one pack leads to) appear once.
final class GraphStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A pack with the mobile schema (pipeline/export_mobile.py) and the given rows.
    private func pack(_ name: String, terms: [(Int, String, String)], edges: [(Int, Int)] = [],
                      meanings: [(Int, String)] = []) throws -> URL {
        let url = dir.appending(path: "\(name).sqlite")
        let db = try SQLiteConnection(url)
        try db.exec("""
            CREATE TABLE family (code TEXT PRIMARY KEY, name TEXT);
            CREATE TABLE language (code TEXT PRIMARY KEY, name TEXT, family TEXT);
            CREATE TABLE language_geo (code TEXT PRIMARY KEY, lat REAL, lon REAL, source TEXT);
            CREATE TABLE term (id INTEGER PRIMARY KEY, lang TEXT NOT NULL, word TEXT NOT NULL,
                               gloss TEXT, zipf REAL, has_entry INTEGER);
            CREATE TABLE edge (src INTEGER NOT NULL, dst INTEGER NOT NULL, kind TEXT NOT NULL,
                               inferred INTEGER NOT NULL, PRIMARY KEY (src, dst, kind)) WITHOUT ROWID;
            CREATE TABLE form (lang TEXT NOT NULL, form TEXT NOT NULL, lemma INTEGER NOT NULL,
                               PRIMARY KEY (lang, form, lemma)) WITHOUT ROWID;
            CREATE TABLE meaning (term INTEGER NOT NULL, key TEXT NOT NULL, PRIMARY KEY (term, key));
            CREATE TABLE open_affix (id INTEGER PRIMARY KEY);
            CREATE UNIQUE INDEX term_lang_word ON term(lang, word);
            CREATE INDEX edge_dst ON edge(dst);
            """)
        for (id, lang, word) in terms {
            try db.exec("INSERT INTO term VALUES (\(id), '\(lang)', '\(word)', NULL, NULL, 1)")
        }
        for (src, dst) in edges {
            try db.exec("INSERT INTO edge VALUES (\(src), \(dst), 'inherited', 0)")
        }
        for (term, key) in meanings {
            try db.exec("INSERT INTO meaning VALUES (\(term), '\(key)')")
        }
        return url
    }

    private func count(_ store: URL, _ sql: String) throws -> Int {
        try SQLiteConnection(store).rows(sql) { $0.int(0) }.first ?? 0
    }

    func testMergeKeepsSharedRowsOnce() async throws {
        // core: Latin pater; it: padre < pater; en: paternal < pater, and padre as a word
        // the English pack leads to (as if English borrowed it)
        let core = try pack("core", terms: [(1, "la", "pater")])
        let it = try pack("it", terms: [(2, "it", "padre")], edges: [(2, 1)],
                          meanings: [(2, "father"), (2, "priest")])
        let en = try pack("en", terms: [(3, "en", "paternal"), (2, "it", "padre")],
                          edges: [(3, 1), (2, 1)])
        let url = dir.appending(path: "graph.sqlite")
        let store = GraphStore(url: url)
        try await store.merge(pack: "graph-core", version: 1, file: core)
        try await store.merge(pack: "graph-it", version: 3, file: it)
        try await store.merge(pack: "graph-en", version: 2, file: en)

        XCTAssertEqual(try count(url, "SELECT count(*) FROM term"), 3)
        XCTAssertEqual(try count(url, "SELECT count(*) FROM edge"), 2)
        let installed = try await store.installed()
        XCTAssertEqual(installed, ["graph-core": 1, "graph-it": 3, "graph-en": 2])
        // a word's meanings keep their order: the first is the main one
        let keys = try SQLiteConnection(url).rows(
            "SELECT key FROM meaning WHERE term=2 ORDER BY rowid") { $0.text(0) }
        XCTAssertEqual(keys, ["father", "priest"])
    }

    func testRebuildLeavesARemovedPackOut() async throws {
        let core = try pack("core", terms: [(1, "la", "pater")])
        let it = try pack("it", terms: [(2, "it", "padre")], edges: [(2, 1)])
        let url = dir.appending(path: "graph.sqlite")
        let store = GraphStore(url: url)
        try await store.merge(pack: "graph-core", version: 1, file: core)
        try await store.merge(pack: "graph-it", version: 1, file: it)
        try await store.rebuild(from: [("graph-core", 1, core)])

        XCTAssertEqual(try count(url, "SELECT count(*) FROM term"), 1)
        XCTAssertEqual(try count(url, "SELECT count(*) FROM edge"), 0)
        let installed = try await store.installed()
        XCTAssertEqual(installed, ["graph-core": 1])
    }

    func testNothingInstalledBeforeTheFirstPack() async throws {
        let store = GraphStore(url: dir.appending(path: "graph.sqlite"))
        let installed = try await store.installed()
        XCTAssertTrue(installed.isEmpty)
    }

    func testPackPathInsideTheAssetPack() {
        XCTAssertEqual(LanguagePacks.path(of: "graph-it").string, "graph/it.sqlite")
        XCTAssertEqual(LanguagePacks.path(of: "graph-en-rare").string, "graph/en-rare.sqlite")
    }

    /// The real packs, when pipeline/export_packs.py has built them on this Mac (the
    /// simulator sees the Mac's files): core, Italian and English merged into one.
    func testRealPacksMerge() async throws {
        let packs = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../pipeline/data/packs").standardized
        let files = ["core", "it", "en"].map { packs.appending(path: "\($0).sqlite") }
        try XCTSkipUnless(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                          "no packs built (pipeline/export_packs.py)")
        let url = dir.appending(path: "graph.sqlite")
        let store = GraphStore(url: url)
        let start = Date()
        for (name, file) in zip(["core", "it", "en"], files) {
            try await store.merge(pack: "graph-\(name)", version: 1, file: file)
        }
        let seconds = Date().timeIntervalSince(start)
        // padre goes back to Latin pater, which the core holds
        let up = try SQLiteConnection(url).rows("""
            SELECT d.lang || ':' || d.word FROM term t JOIN edge e ON e.src=t.id
            JOIN term d ON d.id=e.dst WHERE t.lang='it' AND t.word='padre'
            """) { $0.text(0) }
        XCTAssertFalse(up.isEmpty)
        XCTAssertGreaterThan(try count(url, "SELECT count(*) FROM term WHERE lang='la'"), 10_000)
        print("merged core, it, en in \(String(format: "%.1f", seconds)) s; padre <", up)
    }
}
