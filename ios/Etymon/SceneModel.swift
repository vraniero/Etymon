import CoreGraphics
import Foundation
import Observation

/// The words collected from the surroundings and the network the backend returns for them.
@MainActor
@Observable
final class SceneModel {

    private(set) var words: [String] = []
    private(set) var language: String?
    private(set) var response: SceneResponse?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Where each word currently is in the picture or video (normalized, top-left
    /// origin), keyed by lowercased word, and when it was last seen there.
    private(set) var boxes: [String: CGRect] = [:]
    private(set) var lastSeen: [String: Date] = [:]
    /// Upright size of the image the boxes refer to.
    private(set) var imageSize: CGSize = .zero
    /// The latest picture read carefully, kept for saving the scene.
    private(set) var picture: ScenePicture?
    /// A word not re-found for this long has left the frame; its overlay hides. Longer
    /// than the gap between careful reads, so one missed read doesn't make it flicker.
    static let visibleFor: TimeInterval = 2.5
    /// A new word must be read this many times (careful reads, close together) before it
    /// joins the scene: one-frame misreadings of moving text never get in.
    static let confirmations = 2
    static let confirmWithin: TimeInterval = 3

    /// Candidates seen but not yet confirmed: how many careful reads in a row, and when last.
    private var sightings: [String: (count: Int, last: Date)] = [:]
    /// Words the dictionary doesn't know (misreadings, names): kept out of the scene.
    private(set) var rejected = Set<String>()
    /// True while words come from the camera or a photo (not typed): unknown words are dropped.
    private var collecting = false
    /// The language each spoken word was said in, by lowercased word: sent with the word,
    /// so a conversation in several languages resolves each word in its own.
    private(set) var spokenLanguages: [String: String] = [:]

    /// Text seen so far, for detecting the scene's language.
    private var seenText = ""
    private var pending: Task<Void, Never>?
    private var lastRequested: [String] = []

    var client: () -> APIClient = { APIClient.fromSettings() }

    /// Add recognised text (a camera frame, a photo). Words accumulate across frames, so
    /// a sign read in pieces still builds one scene; the oldest drop off past the word
    /// limit set in Settings.
    func add(text: String) {
        let new = WordExtractor.words(in: text).filter { !rejected.contains($0.lowercased()) }
        guard !new.isEmpty else { return }
        seenText = String((seenText + "\n" + text).suffix(2000))
        var merged = words
        let known = Set(merged.map { $0.lowercased() })
        merged += new.filter { !known.contains($0.lowercased()) }
        let limit = WordLimit.current
        if merged.count > limit {
            merged.removeFirst(merged.count - limit)
        }
        update(words: merged)
    }

    /// What someone said (an utterance, in the language it was detected in). Like the
    /// camera, it collects: the oldest words drop off past the word limit, and words the
    /// dictionary doesn't know (misheard) stay out. Returns the words it brought.
    @discardableResult
    func hear(_ text: String, lang: String?) -> [String] {
        collecting = true
        let heard = WordExtractor.words(in: text).filter { !rejected.contains($0.lowercased()) }
        if let lang {
            for word in heard { spokenLanguages[word.lowercased()] = lang }
        }
        add(text: text)
        return heard
    }

    /// A recognition pass over a camera frame or photo. A full pass may add words; a quick
    /// tracking pass only moves the words already in the scene.
    ///
    /// When more words are in view than the word limit allows, the scene stays stable:
    /// words still in view keep their place, only words that have left the frame make
    /// room, and new words are taken most prominent first (largest on screen, then reading
    /// order), so the same view always gives the same words.
    func see(_ recognition: Recognition, imageSize: CGSize, full: Bool, still: Bool = false,
             picture: ScenePicture.Source? = nil, now: Date = Date()) {
        self.imageSize = imageSize
        collecting = true
        if full, let picture {
            self.picture = ScenePicture(
                source: picture,
                boxes: Dictionary(recognition.words.map { ($0.key, $0.box) }) { a, _ in a },
                size: imageSize)
        }
        let known = Set(words.map { $0.lowercased() })
        let stamp = still ? Date.distantFuture : now
        for word in recognition.words where full || known.contains(word.key) {
            boxes[word.key] = word.box
            lastSeen[word.key] = stamp
        }
        guard full else { return }
        seenText = String((seenText + "\n" + recognition.text).suffix(2000))

        let candidates = confirmed(Self.candidates(in: recognition, scene: words, rejected: rejected),
                                   now: now, still: still)
        guard !candidates.isEmpty else {
            update(words: words)  // language may have changed
            return
        }
        let limit = WordLimit.current
        var kept = words
        // make room only from words that have left the frame, oldest first
        let needed = kept.count + candidates.count - limit
        if needed > 0 {
            let gone = kept.filter { !isVisible($0.lowercased(), at: now) }
            let drop = Set(gone.prefix(needed).map { $0.lowercased() })
            kept.removeAll { drop.contains($0.lowercased()) }
        }
        let room = max(limit - kept.count, 0)
        update(words: kept + candidates.prefix(room).map(\.text))
    }

    /// New words worth adding from one read, most prominent first. Skips what is already in
    /// the scene or known to be unknown, accent-only variants (mía next to mia), and
    /// fragments of a longer word read at the same time (tore inside edicicloeditore) —
    /// the usual misreadings of text in motion.
    static func candidates(in recognition: Recognition, scene: [String],
                           rejected: Set<String>) -> [SeenWord] {
        let sceneKeys = Set(scene.map { $0.lowercased() })
        var folded = Set(scene.map { fold($0) })
        let allKeys = Set(recognition.words.map(\.key)).union(sceneKeys)
        var out: [SeenWord] = []
        for word in recognition.words.sorted(by: moreProminent) {
            let key = word.key
            if sceneKeys.contains(key) || rejected.contains(key) { continue }
            if allKeys.contains(where: { $0 != key && $0.count > key.count && $0.contains(key) }) { continue }
            guard folded.insert(fold(word.text)).inserted else { continue }
            out.append(word)
        }
        return out
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// The candidates read often enough, close enough together, to trust.
    private func confirmed(_ candidates: [SeenWord], now: Date, still: Bool) -> [SeenWord] {
        sightings = sightings.filter { now.timeIntervalSince($0.value.last) < Self.confirmWithin }
        if still { return candidates }  // a photo is read once, carefully
        return candidates.filter { word in
            let count = (sightings[word.key]?.count ?? 0) + 1
            sightings[word.key] = (count, now)
            return count >= Self.confirmations
        }
    }

    /// Larger text first (signs' headlines before their small print), then reading order;
    /// rounded so small recognition jitter between frames doesn't reorder words.
    static func moreProminent(_ a: SeenWord, _ b: SeenWord) -> Bool {
        let ha = (a.box.height * 50).rounded(), hb = (b.box.height * 50).rounded()
        if ha != hb { return ha > hb }
        let ya = (a.box.minY * 20).rounded(), yb = (b.box.minY * 20).rounded()
        if ya != yb { return ya < yb }
        return a.box.minX < b.box.minX
    }

    func isVisible(_ key: String, at date: Date = Date()) -> Bool {
        guard let seen = lastSeen[key] else { return false }
        return date.timeIntervalSince(seen) < Self.visibleFor
    }

    /// Replace the scene with typed words (the first ones, up to the word limit).
    func set(typed text: String) {
        collecting = false
        spokenLanguages = [:]
        seenText = text
        update(words: Array(WordExtractor.words(in: text).prefix(WordLimit.current)))
    }

    /// The word limit changed: drop the oldest words if the scene is now over it.
    func applyWordLimit() {
        let limit = WordLimit.current
        guard words.count > limit else { return }
        update(words: Array(words.suffix(limit)))
    }

    func reset() {
        pending?.cancel()
        words = []
        seenText = ""
        language = nil
        spokenLanguages = [:]
        response = nil
        error = nil
        lastRequested = []
        boxes = [:]
        lastSeen = [:]
        picture = nil
        sightings = [:]
        rejected = []
    }

    /// Show a saved scene as it was: its words where they were in its picture, its network
    /// as the backend gave it then. Nothing is asked of the server.
    func show(saved response: SceneResponse, boxes: [String: CGRect], imageSize: CGSize) {
        pending?.cancel()
        collecting = false
        words = response.words.map(\.text)
        lastRequested = words
        self.response = response
        self.boxes = boxes
        self.imageSize = imageSize
        lastSeen = boxes.mapValues { _ in .distantFuture }
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

    /// Ask again for the same words, e.g. after the search depth changed.
    func refresh() {
        guard !words.isEmpty else { return }
        pending?.cancel()
        pending = Task { [weak self] in await self?.fetch() }
    }

    func fetch() async {
        let requested = words
        guard requested.count >= 1 else { response = nil; return }
        lastRequested = requested
        isLoading = true
        defer { isLoading = false }
        do {
            let depth = SearchDepth.current
            let languages = requested.map { spokenLanguages[$0.lowercased()] }
            let result = try await client().scene(words: requested, lang: language, maxCost: depth,
                                                  wordLanguages: languages)
            // a newer scene, or the same one at another depth, superseded this one
            guard requested == words, depth == SearchDepth.current else { return }
            response = result
            error = nil
            if collecting {
                // words the dictionary doesn't know free their place and stay out
                let unknown = result.words.filter { $0.terms.isEmpty }.map(\.key)
                if !unknown.isEmpty {
                    rejected.formUnion(unknown)
                    words.removeAll { rejected.contains($0.lowercased()) }
                    lastRequested = words  // nothing new to ask: the response already covers them
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            lastRequested = []  // allow a retry for the same words
        }
    }
}
