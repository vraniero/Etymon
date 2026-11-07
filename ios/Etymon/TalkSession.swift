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
    /// The latest utterance, as a caption: who said what.
    private(set) var caption: (speaker: Int, text: String)?
    /// The latest connection made, for the caption: "padre · father".
    private(set) var lastConnection: String?

    /// Words said so far (text, language), latest last: the backend is asked about the most
    /// recent ones together, for links the trees alone don't show (same meanings, roots
    /// further up than the trees reach).
    private var said: [(text: String, lang: String?)] = []
    private var lookedUp = Set<String>()  // "word|lang", asked once each
    /// Every different word said (text, language), for saving the conversation.
    private var everything: [(text: String, lang: String?)] = []
    private var counted = (roots: 0, meanings: 0)
    private var sceneTask: Task<Void, Never>?
    private let stream = ConversationStream()
    let chimes = Chimes()
    var client: () -> APIClient = { APIClient.fromSettings() }

    /// How many recent words go into each scene request.
    static let sceneWindow = 80

    init() {
        stream.onEvent = { [weak self] event in self?.handle(event) }
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
    }

    /// A new, empty space. The voices are still known to the backend while listening.
    func clear() {
        sceneTask?.cancel()
        graph = ExploreGraph()
        said = []
        everything = []
        lookedUp = []
        counted = (0, 0)
        knownMeetings = []
        knownMeanings = []
        caption = nil
        lastConnection = nil
        for i in speakers.indices { speakers[i].words = 0 }
    }

    func report(_ message: String) { error = message }

    // MARK: events

    private func handle(_ event: ConversationStream.Event) {
        switch event {
        case .ready: connecting = false
        case .speech: talking = true
        case .silence: talking = false
        case .utterance(let u):
            connecting = false
            Task { await heard(text: u.text, lang: u.lang, voice: u.persona) }
        case .failed(let message):
            if listening {
                error = "Lost the server: \(message)"
                stop()
            }
        }
    }

    /// An utterance: its speaker, then each new word's tree, then the scene's links.
    func heard(text: String, lang: String?, voice: String) async {
        let number: Int
        if let i = speakers.firstIndex(where: { $0.id == voice }) {
            number = speakers[i].number
            if let lang { speakers[i].lang = lang }
        } else {
            number = speakers.count + 1
            speakers.append(Speaker(id: voice, number: number, lang: lang))
        }
        caption = (number, text)
        let words = WordExtractor.words(in: text)
        guard !words.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for word in words {
                let key = "\(word.lowercased())|\(lang ?? "")"
                guard lookedUp.insert(key).inserted else {
                    // said again: it is this speaker's now
                    recolor(word, lang: lang, speaker: number)
                    continue
                }
                group.addTask { await self.plant(word, lang: lang, speaker: number) }
            }
        }
        said += words.map { ($0, lang) }
        let known = Set(everything.map { "\($0.text.lowercased())|\($0.lang ?? "")" })
        for word in words where !known.contains("\(word.lowercased())|\(lang ?? "")") {
            everything.append((word, lang))
        }
        if said.count > Self.sceneWindow * 2 { said.removeFirst(said.count - Self.sceneWindow) }
        askScene()
    }

    /// One word and its line of ancestors, from the backend (or the device's cache).
    private func plant(_ word: String, lang: String?, speaker: Int) async {
        guard let response = try? await client().word(word, lang: lang),
              let entry = response.entries.first else { return }  // not in the dictionary
        graph.grow(term: entry.term, label: word, lineage: entry.lineage, nodes: response.nodes,
                   speaker: speaker)
        if let i = speakers.firstIndex(where: { $0.number == speaker }) { speakers[i].words += 1 }
        chimeForNewConnections()
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
            lastConnection = describe(root: newMeeting)
        } else if let e = newMeaning, let a = graph.nodes[e.a], let b = graph.nodes[e.b] {
            lastConnection = "\(a.label) = \(b.label)" + (e.meaning.map { " (\($0))" } ?? "")
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
