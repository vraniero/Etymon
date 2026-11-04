import Foundation
import Observation

/// The words collected from the surroundings and the network the backend returns for them.
@MainActor
@Observable
final class SceneModel {
    static let maxWords = 20

    private(set) var words: [String] = []
    private(set) var language: String?
    private(set) var response: SceneResponse?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Text seen so far, for detecting the scene's language.
    private var seenText = ""
    private var pending: Task<Void, Never>?
    private var lastRequested: [String] = []

    var client: () -> APIClient = { APIClient.fromSettings() }

    /// Add recognised text (a camera frame, a photo). Words accumulate across frames, so
    /// a sign read in pieces still builds one scene; the oldest drop off past maxWords.
    func add(text: String) {
        let new = WordExtractor.words(in: text)
        guard !new.isEmpty else { return }
        seenText = String((seenText + "\n" + text).suffix(2000))
        var merged = words
        let known = Set(merged.map { $0.lowercased() })
        merged += new.filter { !known.contains($0.lowercased()) }
        if merged.count > Self.maxWords {
            merged.removeFirst(merged.count - Self.maxWords)
        }
        update(words: merged)
    }

    /// Replace the scene with typed words.
    func set(typed text: String) {
        seenText = text
        update(words: WordExtractor.words(in: text))
    }

    func reset() {
        pending?.cancel()
        words = []
        seenText = ""
        language = nil
        response = nil
        error = nil
        lastRequested = []
    }

    private func update(words newWords: [String]) {
        words = newWords
        language = WordExtractor.dominantLanguage(of: seenText)
        guard newWords != lastRequested else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            // debounce: frames arrive in bursts while the camera settles
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.fetch()
        }
    }

    func fetch() async {
        let requested = words
        guard requested.count >= 1 else { response = nil; return }
        lastRequested = requested
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client().scene(words: requested, lang: language)
            guard requested == words else { return }  // a newer scene superseded this one
            response = result
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            lastRequested = []  // allow a retry for the same words
        }
    }
}
