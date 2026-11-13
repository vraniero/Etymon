import SwiftUI

/// Root Chain, the word game. Players take turns adding a word that shares an ancestor
/// with the last one: father → padre (Proto-Indo-European *ph₂tḗr) → paternal (Latin
/// pater) → … A link may not go through the same ancestor as the link before it, and no
/// word (or form of one) is played twice. Points for each link, more for a change of
/// language or an ancient root; first to the target wins, and three misses and you're out.
///
/// Every move, the app's own included, is checked the same way: POST /scene with the last
/// word and the new one, which is also what draws the link.
enum ChainRules {
    static let target = 10
    static let lives = 3

    /// The opening words: common, with long and branching ancestries.
    static let starters = ["father", "mother", "night", "star", "water", "heart", "new", "three",
                           "name", "sun", "foot", "tooth", "eye", "nose", "wine", "salt",
                           "house", "milk", "bread", "king", "light", "sea", "garden", "music"]

    enum Verdict: Equatable {
        case link(Connection, points: Int)
        /// Not a move: the word isn't known (a typo costs nothing).
        case unknown
        /// A miss: costs a life.
        case played(before: String)
        case noLink
        case sameRoot
    }

    /// `scene`: the answer for [last word, new word]. `played`: the words so far, lower
    /// case, and their term ids. `lastRoot`: the ancestor the previous link went through.
    static func judge(_ scene: SceneResponse, played: Set<String>, playedTerms: Set<Int>,
                      lastRoot: Int?) -> Verdict {
        guard scene.words.count == 2 else {
            // the backend folds a repeated word into one
            return .played(before: scene.words.first?.text ?? "")
        }
        let new = scene.words[1]
        if new.terms.isEmpty { return .unknown }
        if played.contains(new.key) || !playedTerms.isDisjoint(with: new.terms) {
            return .played(before: new.text)
        }
        guard let link = scene.connections.first else { return .noLink }
        if link.meet == lastRoot { return .sameRoot }
        return .link(link, points: points(for: link, in: scene))
    }

    /// 1 for the link, +1 if the language changes, +1 if the shared ancestor is a
    /// reconstructed one (only known from comparing its descendants: *ph₂tḗr).
    static func points(for link: Connection, in scene: SceneResponse) -> Int {
        var points = 1
        if let a = scene.words.first?.lang, let b = scene.words.last?.lang, a != b { points += 1 }
        if scene.node(link.meet)?.reconstructed == true { points += 1 }
        return points
    }

    static func explain(_ verdict: Verdict) -> String {
        switch verdict {
        case .link: return ""
        case .unknown: return "Etymon doesn't know that word. Try another — no life lost."
        case .played(let word): return "“\(word)” has been played already."
        case .noLink: return "No shared ancestor found with the last word."
        case .sameRoot: return "That goes through the same ancestor as the last link. Branch somewhere else."
        }
    }
}

/// Who plays: two people on one phone, or one person against the app.
enum ChainOpponent: Hashable {
    case app(ChainLevel)
    case friend
}

enum ChainLevel: String, CaseIterable, Identifiable {
    case easy, normal, hard
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var blurb: String {
        switch self {
        case .easy: "Common words, close relatives, in English and the last word's language."
        case .normal: "Less common words, a bit further back."
        case .hard: "Any of twenty languages, rare words, old roots."
        }
    }
}

struct ChainPlayer: Identifiable {
    let id: Int
    var name: String
    let color: Color
    let isApp: Bool
    var score = 0
    var lives = ChainRules.lives
}

/// One word in the chain, and the link that joined it to the word before.
struct ChainMove: Identifiable {
    let id = UUID()
    let player: Int?  // nil: the opening word
    let text: String
    let lang: String?
    let language: String?  // its name
    let link: Connection?
    let points: Int
    let scene: SceneResponse?  // [previous word, this word], for drawing the link
}

@MainActor @Observable
final class ChainGame {
    let opponent: ChainOpponent
    /// The game's language: words are looked up in it and Etymon plays in it. nil: any.
    let language: String?
    private(set) var players: [ChainPlayer]
    private(set) var moves: [ChainMove] = []
    private(set) var turn = 0
    private(set) var busy = false
    /// What the last attempt went wrong with, for the player whose turn it is.
    private(set) var message: String?
    private(set) var winner: Int?
    var api = APIClient.fromSettings()
    private let chimes = Chimes()
    private var played: Set<String> = []
    private var playedTerms: Set<Int> = []

    init(opponent: ChainOpponent, names: [String] = ["You", "Friend"],
         start: String = ChainRules.starters.randomElement()!, startLang: String = "en",
         language: String? = nil) {
        self.opponent = opponent
        self.language = language
        switch opponent {
        case .app:
            players = [ChainPlayer(id: 0, name: names[0], color: IconPalette.mint, isApp: false),
                       ChainPlayer(id: 1, name: "Etymon", color: IconPalette.gold, isApp: true)]
        case .friend:
            players = [ChainPlayer(id: 0, name: names[0], color: IconPalette.mint, isApp: false),
                       ChainPlayer(id: 1, name: names[1], color: IconPalette.violet, isApp: false)]
        }
        moves = [ChainMove(player: nil, text: start, lang: startLang,
                           language: TalkCaption.name(startLang), link: nil,
                           points: 0, scene: nil)]
        played = [start.lowercased()]
    }

    var current: ChainPlayer { players[turn] }
    var last: ChainMove { moves[moves.count - 1] }
    var isOver: Bool { winner != nil }
    private var lastRoot: Int? { last.link?.meet }

    /// The opening word's terms, so its forms can't be played (fathers after father).
    func prepare() async {
        guard playedTerms.isEmpty, let first = moves.first,
              let word = try? await api.word(first.text, lang: first.lang) else { return }
        playedTerms.formUnion(word.entries.map(\.term))
    }

    /// The person whose turn it is plays `text`.
    func play(_ text: String) async {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !busy, !isOver, !current.isApp else { return }
        message = nil
        await attempt(word, lang: language)
    }

    /// Give up this turn: costs a life, and the other player goes on from the same word.
    func pass() {
        guard !busy, !isOver else { return }
        miss("\(current.name) passed.")
    }

    private func attempt(_ word: String, lang: String?) async {
        busy = true
        defer { busy = false }
        do {
            let scene = try await api.scene(words: [last.text, word], lang: nil,
                                            wordLanguages: [last.lang, lang])
            let verdict = ChainRules.judge(scene, played: played, playedTerms: playedTerms,
                                           lastRoot: lastRoot)
            switch verdict {
            case .link(let link, let points):
                accept(scene, link: link, points: points)
            case .unknown:
                message = ChainRules.explain(verdict)
            default:
                miss(ChainRules.explain(verdict))
            }
        } catch {
            message = "Can't reach the server: \(error.localizedDescription). No life lost."
        }
    }

    private func accept(_ scene: SceneResponse, link: Connection, points: Int) {
        let new = scene.words[1]
        withAnimation(.spring(duration: 0.5)) {
            moves.append(ChainMove(player: turn, text: new.text, lang: new.lang,
                                   language: new.terms.first.flatMap { scene.node($0)?.language },
                                   link: link, points: points, scene: scene))
            players[turn].score += points
        }
        played.insert(new.key)
        playedTerms.formUnion(new.terms)
        chimes.play(.root)
        if players[turn].score >= ChainRules.target {
            winner = turn
        } else {
            nextTurn()
        }
    }

    private func miss(_ why: String) {
        message = why
        withAnimation { players[turn].lives -= 1 }
        if players[turn].lives <= 0 {
            winner = 1 - turn
        } else {
            nextTurn()
        }
    }

    private func nextTurn() {
        turn = 1 - turn
        if current.isApp {
            Task { await appMove() }
        }
    }

    /// The app finds a word and plays it like anyone else; when it has none, it passes.
    private func appMove() async {
        guard case .app(let level) = opponent, !isOver else { return }
        busy = true
        let started = Date()
        let reply = try? await api.chainReply(after: last.text, lang: last.lang,
                                              used: Array(played), avoidRoot: lastRoot,
                                              level: level.rawValue, in: language)
        // a moment to think, so its move doesn't land on top of yours
        let pause = 0.9 - Date().timeIntervalSince(started)
        if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
        busy = false
        guard let reply else {
            miss("Etymon couldn't find a word, and passed.")
            return
        }
        let before = moves.count
        await attempt(reply.text, lang: reply.lang)
        // its word came back unknown (offline, or a word the scene reads differently)
        if moves.count == before, current.isApp, !isOver {
            miss("Etymon's word didn't hold up, and it passed.")
        }
    }
}
