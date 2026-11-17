import BackgroundAssets
import Foundation
import Observation
import SwiftUI
import System

/// The dictionary's packs, hosted by the App Store (pipeline/export_packs.py): a core of
/// ancient words every language climbs into, downloaded with the app, then one pack per
/// language. The phone's own languages and English come first; any other language is
/// offered the first time the app reads it (a sign, a photo, typed text), or from Settings.
/// Each pack is merged into one database on the phone (GraphStore), then its download is
/// let go, so nothing is stored twice.
@MainActor
@Observable
final class LanguagePacks {
    static let shared = LanguagePacks()

    /// Off until lookups run on the phone (today they go to the backend, so a downloaded
    /// pack changes nothing yet): on with the `-packs` launch argument, to try downloading.
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-packs") }

    enum State: Equatable {
        case absent
        case downloading(Double)  // fraction done
        case installing  // merging into the dictionary
        case installed
        case failed(String)
    }

    /// The core every language needs.
    static let core = "graph-core"
    /// English words past the common ones: a pack of its own, the biggest, optional.
    static let rareEnglish = "graph-en-rare"
    static func pack(for language: String) -> String { "graph-\(language)" }

    private(set) var states: [String: State] = [:]
    /// Download sizes in bytes, once the App Store has said.
    private(set) var sizes: [String: Int] = [:]
    /// A language just read that isn't on the phone: shown as an offer to download it.
    private(set) var offer: String?

    let store: GraphStore
    private var started = false
    private static let declinedKey = "declinedLanguagePacks"

    init(store: GraphStore = GraphStore(url: GraphStore.defaultURL)) {
        self.store = store
    }

    func state(of pack: String) -> State { states[pack] ?? .absent }
    func isInstalled(_ language: String) -> Bool { state(of: Self.pack(for: language)) == .installed }

    /// On launch: what the phone already has, then the core, English and the phone's own
    /// languages, then any newer versions of the packs held.
    func start() async {
        guard !started else { return }
        started = true
        for id in (try? await store.installed().keys).map(Array.init) ?? [] {
            states[id] = .installed
        }
        await loadSizes()
        for id in [Self.core] + Self.preferredLanguages.map(Self.pack(for:))
        where state(of: id) == .absent {
            await install(id)
        }
        await applyUpdates()
    }

    /// Wiktionary codes of the phone's languages that have a pack, English always.
    static var preferredLanguages: [String] {
        let phone = Locale.preferredLanguages.map { WordExtractor.code(forSystem: $0) }
        return Array(NSOrderedSet(array: phone + ["en"]))
            .compactMap { $0 as? String }
            .filter { WordExtractor.languages.contains($0) }
    }

    /// The app read text in this language: offer its pack if it isn't here yet (once: a
    /// language turned down isn't offered again, Settings still has it).
    func noticed(language: String?) {
        guard started, let language, WordExtractor.languages.contains(language),
              state(of: Self.pack(for: language)) == .absent,
              !declined.contains(language), offer == nil else { return }
        withAnimation(.spring) { offer = language }
    }

    func acceptOffer() {
        guard let language = offer else { return }
        withAnimation(.spring) { offer = nil }
        Task { await install(Self.pack(for: language)) }
    }

    func declineOffer() {
        guard let language = offer else { return }
        withAnimation(.spring) { offer = nil }
        UserDefaults.standard.set(Array(declined.union([language])), forKey: Self.declinedKey)
    }

    private var declined: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? [])
    }

    /// Download a pack and merge it into the dictionary.
    func install(_ id: String) async {
        switch state(of: id) {
        case .downloading, .installing, .installed: return
        default: break
        }
        states[id] = .downloading(0)
        let manager = AssetPackManager.shared
        let progress = Task { [weak self] in
            for await update in manager.statusUpdates(forAssetPackWithID: id) {
                if case .downloading(_, let p) = update {
                    await MainActor.run { self?.states[id] = .downloading(p.fractionCompleted) }
                }
            }
        }
        defer { progress.cancel() }
        do {
            let pack = try await Self.assetPack(id)
            sizes[id] = pack.downloadSize
            try await manager.ensureLocalAvailability(of: pack)
            progress.cancel()
            states[id] = .installing
            let file = try manager.url(for: Self.path(of: id))
            try await store.merge(pack: id, version: pack.version, file: file)
            try? await manager.remove(assetPackWithID: id)  // merged: the download can go
            states[id] = .installed
        } catch {
            states[id] = .failed(error.localizedDescription)
        }
    }

    /// Take a language off the phone: the dictionary is rebuilt from the packs that stay,
    /// downloaded again (merged rows can't be told apart by pack).
    func remove(_ id: String) async {
        guard id != Self.core, state(of: id) == .installed else { return }
        let keep = ((try? await store.installed().keys).map(Array.init) ?? []).filter { $0 != id }
        await rebuild(keep, dropping: id)
    }

    /// Newer versions of packs on the phone (a data update): rebuild with them.
    func applyUpdates() async {
        guard let installed = try? await store.installed(), !installed.isEmpty,
              let (updating, _) = try? await AssetPackManager.shared.checkForUpdates(),
              !updating.isDisjoint(with: installed.keys) else { return }
        await rebuild(Array(installed.keys), dropping: nil)
    }

    private func rebuild(_ ids: [String], dropping: String?) async {
        let manager = AssetPackManager.shared
        for id in ids { states[id] = .installing }
        if let dropping { states[dropping] = .installing }
        do {
            var packs: [(id: String, version: Int, file: URL)] = []
            for id in ids {
                let pack = try await Self.assetPack(id)
                try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: true)
                packs.append((id, pack.version, try manager.url(for: Self.path(of: id))))
            }
            try await store.rebuild(from: packs)
            for id in ids {
                try? await manager.remove(assetPackWithID: id)
                states[id] = .installed
            }
            if let dropping { states[dropping] = .absent }
        } catch {
            for id in ids { states[id] = .installed }  // the old dictionary is still in place
            if let dropping { states[dropping] = .failed(error.localizedDescription) }
        }
    }

    private func loadSizes() async {
        guard let packs = try? await Self.allPacks() else { return }
        for pack in packs { sizes[pack.id] = pack.downloadSize }
    }

    /// The database file inside a pack (export_packs.py: graph/<language>.sqlite).
    nonisolated static func path(of id: String) -> FilePath {
        FilePath("graph/\(id.dropFirst("graph-".count)).sqlite")
    }

    private static func assetPack(_ id: String) async throws -> AssetPack {
        if #available(iOS 27, *) {
            guard let pack = try await AssetPackManager.shared.manifest.assetPack(withID: id) else {
                throw ManagedBackgroundAssetsError.assetPackNotFound(withID: id)
            }
            return pack
        }
        return try await AssetPackManager.shared.assetPack(withID: id)
    }

    private static func allPacks() async throws -> Set<AssetPack> {
        if #available(iOS 27, *) {
            return try await AssetPackManager.shared.manifest.assetPacks
        }
        return try await AssetPackManager.shared.allAssetPacks
    }

    /// A language's name in the phone's language: "Italian", "Serbo-Croatian".
    static func name(of language: String) -> String {
        if language == "sh" { return "Serbo-Croatian" }
        return Locale.current.localizedString(forLanguageCode: language) ?? language
    }
}
