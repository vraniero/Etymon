import Foundation
import SQLite3

/// The dictionary on the phone: one SQLite database, built from the packs downloaded so far
/// (pipeline/export_packs.py). Each pack has the same schema; rows two packs share are
/// identical, so merging is INSERT OR IGNORE and the order packs arrive in doesn't matter.
/// Records which packs (and which versions) it holds.
actor GraphStore {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The tables a pack holds, all merged.
    static let tables = ["family", "language", "language_geo", "term", "edge", "form",
                         "meaning", "open_affix"]

    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// Where the app keeps it: Application Support, not backed up (packs come back from
    /// the App Store).
    static var defaultURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Dictionary", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = dir
        try? excluded.setResourceValues(values)
        return dir.appending(path: "graph.sqlite")
    }

    /// Pack id -> version, for every pack merged in.
    func installed() throws -> [String: Int] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let db = try SQLiteConnection(url)
        try db.exec(Self.bookkeeping)
        return Dictionary(uniqueKeysWithValues: try db.rows(
            "SELECT id, version FROM installed_pack") { ($0.text(0), $0.int(1)) })
    }

    /// Merge a downloaded pack's database in.
    func merge(pack id: String, version: Int, file: URL) throws {
        try Self.merge(into: url, pack: id, version: version, file: file)
    }

    /// Build the database again from these packs only (a language removed, or a pack
    /// updated: rows can't be taken out of a merge one pack at a time). Built aside and
    /// swapped in, so the old one stays usable until the new one is complete.
    func rebuild(from packs: [(id: String, version: Int, file: URL)]) throws {
        let fresh = url.deletingLastPathComponent().appending(path: "graph-rebuilding.sqlite")
        try? FileManager.default.removeItem(at: fresh)
        for pack in packs {
            try Self.merge(into: fresh, pack: pack.id, version: pack.version, file: pack.file)
        }
        if packs.isEmpty {
            try SQLiteConnection(fresh).exec(Self.bookkeeping)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: fresh)
        } else {
            try FileManager.default.moveItem(at: fresh, to: url)
        }
    }

    private static let bookkeeping =
        "CREATE TABLE IF NOT EXISTS installed_pack (id TEXT PRIMARY KEY, version INTEGER NOT NULL)"

    private static func merge(into target: URL, pack id: String, version: Int, file: URL) throws {
        let db = try SQLiteConnection(target)
        try db.exec(bookkeeping)
        try db.exec("ATTACH DATABASE \(quoted(file.path)) AS pack")
        defer { try? db.exec("DETACH DATABASE pack") }
        let hasGraph = try !db.rows(
            "SELECT 1 FROM main.sqlite_master WHERE name='term'") { _ in true }.isEmpty
        if !hasGraph {
            // the schema, tables before their indexes, from the pack itself
            let schema = try db.rows(
                "SELECT sql FROM pack.sqlite_master WHERE sql IS NOT NULL "
                + "AND name NOT LIKE 'sqlite_%' ORDER BY type DESC") { $0.text(0) }
            for sql in schema { try db.exec(sql) }
        }
        try db.exec("BEGIN")
        do {
            for table in tables {
                try db.exec("INSERT OR IGNORE INTO main.\(table) SELECT * FROM pack.\(table)")
            }
            try db.exec("INSERT OR REPLACE INTO installed_pack VALUES (\(quoted(id)), \(version))")
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

/// A minimal SQLite connection: enough to merge packs and read the bookkeeping.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(_ url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw GraphStore.Failure(message: "\(url.lastPathComponent): \(message)")
        }
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "failed"
            sqlite3_free(error)
            throw GraphStore.Failure(message: message)
        }
    }

    struct Row {
        fileprivate let statement: OpaquePointer?
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    }

    func rows<T>(_ sql: String, _ read: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GraphStore.Failure(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(read(Row(statement: statement))) }
        return out
    }
}
