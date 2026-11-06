import CryptoKit
import Foundation

/// Backend answers kept on the device, one file per question (a word's lineage, a node's
/// neighbors), so what has been looked up before still works without the server. Kept in
/// Application Support, not Caches: it is part of the user's offline network, and the
/// system must not purge it.
struct OfflineCache: Sendable {
    static let shared = OfflineCache(directory: URL.applicationSupportDirectory
        .appending(path: "ResponseCache", directoryHint: .isDirectory))

    let directory: URL

    /// The question without the server address: the same lookup on another server is the
    /// same answer.
    static func key(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = (components?.queryItems ?? []).sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return url.path() + "?" + query
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: file(for: key))
    }

    func store(_ data: Data, for key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: key), options: .atomic)
    }

    /// Number of answers kept and their total size in bytes.
    func usage() -> (count: Int, bytes: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
        return (files.count, bytes)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest + ".json")
    }
}
