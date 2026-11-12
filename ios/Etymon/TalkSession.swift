import Foundation
import Observation

/// Talk: a conversation growing a network in a virtual space. The microphone streams to
/// the backend, which tells the voices apart (each a speaker) and transcribes what they
/// say, utterance by utterance, in the language it was said in. Each word said joins the
/// space at once in its speaker's colour with its tree of ancestors above it; where two
/// trees reach the same ancestor, or two words mean the same, a connection is made, and
/// the app chimes.
@MainActor
@Observable
final class TalkSession {
    struct Speaker: Identifiable, Equatable {
        let id: String  // the backend's voice: P1, P2…
        let number: Int  // in order of first speaking: its name and colour
        var lang: String?
        var words = 0
        var title: String { "Speaker \(number)" }
    }

    private(set) var graph = ExploreGraph()
    private(set) var speakers: [Speaker] = []
    private(set) var listening = false
    private(set) var connecting = false  // the backend loads its models on the first connection
    private(set) var talking = false
    private(set) var error: String?

    /// What the listening is doing now, for the status line under the controls.
    enum Phase: Equatable {
        case off, connecting
        case listening  // ready, no one talking
        case hearing  // someone is talking
        case understanding  // transcribing what was said
    }

    var phase: Phase {
        guard listening else { return .off }
        if connecting { return .connecting }
        if talking { return .hearing }
        return understanding > 0 ? .understanding : .listening
    }

    /// Utterances heard and not transcribed yet.
    private(set) var understanding = 0
    /// How loud the microphone is now, 0…1.
    private(set) var level: Float = 0
    /// The languages the backend understands (Wiktionary codes), once it's ready.
    private(set) var languages: [String] = []

    /// What became of each word said: looked up, found with its tree, or not in the
    /// dictionary. Short and common words aren't looked up at all.
    enum WordState: Equatable { case looking, found, missing }

    /// The latest utterance, as a caption: who said what, in which language, and each
    /// word's fate. Fades after a few seconds: the trees stay, the words said don't.
    struct Caption: Equatable {
        let id: Int
        let speaker: Int
        let text: String
        let lang: String?
        let detected: String?
        var words: [String: WordState]  // by lowercased word
    }

    private(set) var caption: Caption?
    private var captionFade: Task<Void, Never>?
    private var nextCaption = 1
    /// A short note in place of a caption: a sound heard with no words in it.
    private(set) var notice: String?
    private var noticeFade: Task<Void, Never>?

    /// The language last spoken (Wiktionary code), or last detected if Etymon doesn't know it;
    /// `lastLanguageKnown` says which.
    private(set) var lastLanguage: String?
    private(set) var lastLanguageKnown = true

    /// Connections made so far: shared roots plus same meanings.
    var connectionCount: Int { graph.connections.roots + graph.connections.meanings }

    /// Words said, and how many of them grew a tree.
    private(set) var wordsHeard = 0
    private(set) var wordsFound = 0
    private var wordTimes: [Date] = []
    /// Words said in the last minute.
    var wordsPerMinute: Int {
        let since = Date().addingTimeInterval(-60)
        return wordTimes.filter { $0 > since }.count
    }
    private var outcome: [String: WordState] = [:]  // "word|lang": what its lookup found
    /// The latest connection made, for the caption: "padre · father".
    /// Fades after a few seconds, like the caption.
    private(set) var lastConnection: String?
    private var connectionFade: Task<Void, Never>?
    static let connectionSeconds = 4.0

    /// Words said so far (text, language), latest last: the backend is asked about the most
    /// recent ones together, for links the trees alone don't show (same meanings, roots
    /// further up than the trees reach).
    private var said: [(text: String, lang: String?)] = []
    private var lookedUp = Set<String>()  // "word|lang", asked once each
    /// Every different word said (text, language), for saving the conversation.
    private var everything: [(text: String, lang: String?)] = []
    /// Who said each word last ("word|lang" -> speaker number), for Connect's speaker choice.
    private var saidBy: [String: Int] = [:]

    /// Connect: the conversation as a network of its connections (shared roots, same
    /// meanings), the backend's answer for every word said by the chosen speakers. Kept up
    /// to date only while it's on screen.
    private(set) var connectScene: SceneResponse?
    private(set) var connectLoading = false
    var connectShown = false {
        didSet { if connectShown, !oldValue { askConnect(soon: false) } }
    }
    /// Only these speakers' words (numbers); empty: everyone.
    var connectSpeakers: Set<Int> = [] {
        didSet { if connectShown, connectSpeakers != oldValue { askConnect(soon: false) } }
    }
    private var connectTask: Task<Void, Never>?
    private var counted = (roots: 0, meanings: 0)
    private var sceneTask: Task<Void, Never>?
    private let stream = ConversationStream()
    let chimes = Chimes()
    var client: () -> APIClient = { APIClient.fromSettings() }

    /// How many recent words go into each scene request.
    static let sceneWindow = 80

    init() {
        stream.onEvent = { [weak self] event in self?.handle(event) }
        stream.onLevel = { [weak self] level in
            guard let self, self.listening else { return }
            self.level = level
        }
    }

    var isEmpty: Bool { graph.nodes.isEmpty }

    func start() async {
        guard !listening else { return }
        error = nil
        connecting = true
        listening = true
        do {
            try await stream.start(base: client().baseURL)
        } catch {
            self.error = error.localizedDescription
            listening = false
            connecting = false
        }
    }

    func stop() {
        guard listening else { return }
        stream.stop()
        listening = false
        connecting = false
        talking = false
        understanding = 0
        level = 0
    }

    /// A new, empty space. The voices are still known to the backend while listening.
    func clear() {
        sceneTask?.cancel()
        graph = ExploreGraph()
        said = []
        everything = []
        saidBy = [:]
        connectTask?.cancel()
        connectScene = nil
        connectLoading = false
        lookedUp = []
        counted = (0, 0)
        knownMeetings = []
        knownMeanings = []
        captionFade?.cancel()
        caption = nil
        notice = nil
        connectionFade?.cancel()
        lastConnection = nil
        wordsHeard = 0
        wordsFound = 0
        lastLanguage = nil
        wordTimes = []
        outcome = [:]
        for i in speakers.indices { speakers[i].words = 0 }
    }

    func report(_ message: String) { error = message }

    // MARK: events

    func handle(_ event: ConversationStream.Event) {
        switch event {
        case .ready(let languages):
            connecting = false
            self.languages = languages
        case .speech: talking = true
        case .silence(_, let kept):
            talking = false
            if kept { understanding += 1 }
        case .unheard:
            understanding = max(understanding - 1, 0)
            say("Heard a sound — no words in it")
        case .utterance(let u):
            connecting = false
            understanding = max(understanding - 1, 0)
            Task { await heard(text: u.text, lang: u.lang, voice: u.persona, detected: u.detected) }
        case .failed(let message):
            if listening {
                error = "Lost the server: \(message)"
                stop()
            }
        }
    }

    /// An utterance: its speaker, then each new word's tree, then the scene's links.
    func heard(text: String, lang: String?, voice: String, detected: String? = nil) async {
        let number: Int
        if let i = speakers.firstIndex(where: { $0.id == voice }) {
            number = speakers[i].number
            if let lang { speakers[i].lang = lang }
        } else {
            number = speakers.count + 1
            speakers.append(Speaker(id: voice, number: number, lang: lang))
        }
        if let heardIn = lang ?? detected {
            lastLanguage = heardIn
            lastLanguageKnown = lang != nil
        }
        let words = WordExtractor.words(in: text)
        let id = nextCaption
        nextCaption += 1
        show(caption: Caption(id: id, speaker: number, text: text, lang: lang, detected: detected ?? lang,
                              words: Dictionary(words.map { ($0.lowercased(), outcome["\($0.lowercased())|\(lang ?? "")"] ?? .looking) },
                                                uniquingKeysWith: { a, _ in a })))
        wordsHeard += words.count
        wordTimes = wordTimes.filter { $0 > Date().addingTimeInterval(-60) } + words.map { _ in Date() }
        guard !words.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for word in words {
                let key = "\(word.lowercased())|\(lang ?? "")"
                guard lookedUp.insert(key).inserted else {
                    // said again: it is this speaker's now
                    recolor(word, lang: lang, speaker: number)
                    if outcome[key] == .found { wordsFound += 1 }
                    continue
                }
                group.addTask {
                    let found = await self.plant(word, lang: lang, speaker: number)
                    await self.settle(word, key: key, found: found, caption: id)
                }
            }
        }
        said += words.map { ($0, lang) }
        let known = Set(everything.map { "\($0.text.lowercased())|\($0.lang ?? "")" })
        for word in words where !known.contains("\(word.lowercased())|\(lang ?? "")") {
            everything.append((word, lang))
        }
        for word in words { saidBy["\(word.lowercased())|\(lang ?? "")"] = number }
        if connectShown { askConnect(soon: true) }
        if said.count > Self.sceneWindow * 2 { said.removeFirst(said.count - Self.sceneWindow) }
        askScene()
    }

    /// A word's lookup is done: count it, and mark it in the caption if that's still up.
    private func settle(_ word: String, key: String, found: Bool, caption id: Int) {
        let state: WordState = found ? .found : .missing
        outcome[key] = state
        if found { wordsFound += 1 }
        if caption?.id == id { caption?.words[word.lowercased()] = state }
    }

    /// One word and its line of ancestors, from the backend (or the device's cache).
    /// False when it isn't in the dictionary.
    @discardableResult
    private func plant(_ word: String, lang: String?, speaker: Int) async -> Bool {
        guard let response = try? await client().word(word, lang: lang),
              let entry = response.entries.first else { return false }
        graph.grow(term: entry.term, label: word, lineage: entry.lineage, nodes: response.nodes,
                   speaker: speaker)
        if let i = speakers.firstIndex(where: { $0.number == speaker }) { speakers[i].words += 1 }
        chimeForNewConnections()
        return true
    }

    private func recolor(_ word: String, lang: String?, speaker: Int) {
        guard let id = graph.sceneWords.first(where: {
            graph.nodes[$0]?.label.lowercased() == word.lowercased()
        }) else { return }
        guard let node = graph.nodes[id] else { return }
        graph.grow(term: id, label: node.label, lineage: [], nodes: [:], speaker: speaker)
    }

    /// The whole conversation as one scene, for the library: every word said, in the language
    /// it was said in, and the network the backend finds among them. Saved scenes keep the
    /// backend's answer; their trees come back from the lookups cached on the device.
    func sceneForSaving() async throws -> SceneResponse {
        let words = Array(everything.suffix(400))  // the backend takes up to 500
        return try await client().scene(words: words.map(\.text), lang: nil, maxCost: SearchDepth.current,
                                        wordLanguages: words.map(\.lang))
    }

    /// Who spoke, for the saved scene's note: "Speaker 1 (it, 12 words) · Speaker 2 (en, 9)".
    var speakersSummary: String {
        speakers.map { "\($0.title) (\([$0.lang, "\($0.words) words"].compactMap { $0 }.joined(separator: ", ")))" }
            .joined(separator: " · ")
    }

    /// The words Connect shows: everything said (up to the backend's limit), or only what
    /// the chosen speakers said.
    var connectWords: [(text: String, lang: String?)] {
        let picked = everything.filter {
            connectSpeakers.isEmpty
                || saidBy["\($0.text.lowercased())|\($0.lang ?? "")"].map(connectSpeakers.contains) == true
        }
        return Array(picked.suffix(400))
    }

    /// Connect's network, again: at once when it opens or the speakers change, after a
    /// moment's pause while words keep coming.
    private func askConnect(soon: Bool) {
        connectTask?.cancel()
        let words = connectWords
        guard !words.isEmpty else {
            connectScene = nil
            return
        }
        connectLoading = true
        connectTask = Task {
            if soon { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            let response = try? await client().scene(
                words: words.map(\.text), lang: nil, maxCost: SearchDepth.current,
                wordLanguages: words.map(\.lang))
            guard !Task.isCancelled else { return }
            connectLoading = false
            if let response {
                connectScene = response
                graph.merge(response)  // what Connect finds, Explore shows too
                chimeForNewConnections()
            }
        }
    }

    /// The recent words together: same meanings across languages, deeper shared roots.
    private func askScene() {
        sceneTask?.cancel()
        let recent = Array(said.suffix(Self.sceneWindow))
        guard recent.count >= 2 else { return }
        sceneTask = Task {
            try? await Task.sleep(for: .milliseconds(400))  // utterances come in bursts
            guard !Task.isCancelled else { return }
            guard let response = try? await client().scene(
                words: recent.map(\.text), lang: nil, maxCost: SearchDepth.current,
                wordLanguages: recent.map(\.lang)), !Task.isCancelled else { return }
            graph.merge(response)
            chimeForNewConnections()
        }
    }

    private func chimeForNewConnections() {
        let now = graph.connections
        let roots = max(now.roots - counted.roots, 0), meanings = max(now.meanings - counted.meanings, 0)
        counted = now
        let meetings = Set(graph.nodes.values.filter { $0.role == .meeting }.map(\.id))
        let newMeeting = meetings.subtracting(knownMeetings).sorted().first
        knownMeetings = meetings
        let meaningEdges = graph.edges.filter(\.isMeaning)
        let newMeaning = meaningEdges.subtracting(knownMeanings).first
        knownMeanings = meaningEdges
        guard roots + meanings > 0 else { return }
        for _ in 0..<min(roots, 4) { chimes.play(.root) }
        for _ in 0..<min(meanings, 4) { chimes.play(.meaning) }
        if let newMeeting {
            show(connection: describe(root: newMeeting))
        } else if let e = newMeaning, let a = graph.nodes[e.a], let b = graph.nodes[e.b] {
            show(connection: "\(a.label) = \(b.label)" + (e.meaning.map { " (\($0))" } ?? ""))
        }
    }

    private func show(connection text: String?) {
        guard let text else { return }
        lastConnection = text
        connectionFade?.cancel()
        connectionFade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectionSeconds))
            guard !Task.isCancelled else { return }
            self?.lastConnection = nil
        }
    }

    /// Long enough to read: 4 s, plus a little for long utterances, at most 8 s.
    static func captionSeconds(_ text: String) -> Double {
        min(4 + Double(text.count) / 40, 8)
    }

    private func say(_ text: String) {
        notice = text
        noticeFade?.cancel()
        noticeFade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func show(caption new: Caption) {
        caption = new
        notice = nil
        captionFade?.cancel()
        captionFade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.captionSeconds(new.text)))
            guard !Task.isCancelled else { return }
            self?.caption = nil
        }
    }

    private var knownMeetings = Set<Int>()
    private var knownMeanings = Set<ExploreGraph.XEdge>()

    /// A shared root and the words said that it joins: "*ph₂tḗr · father · padre".
    func describe(root: Int) -> String? {
        guard let meet = graph.nodes[root] else { return nil }
        var words: [String] = []
        var frontier = [root]
        var seen = Set(frontier)
        while let next = frontier.popLast() {  // down the tree to the words said
            for e in graph.edges where !e.isMeaning && e.b == next && seen.insert(e.a).inserted {
                if let n = graph.nodes[e.a], n.role == .scene { words.append(n.label) }
                frontier.append(e.a)
            }
        }
        return ([meet.label] + words.sorted().prefix(4)).joined(separator: " · ")
    }
}
