import SwiftUI

/// Impostor: four words, three of one family. Tap the one that only looks the part, then
/// see how the family goes back to its ancestor and where the impostor really comes from.
/// Solo or up to six on one phone: each picks in secret on the same puzzle, then all
/// answers are shown. Points for each right answer, more on a streak.
struct ImpostorView: View {
    static let soloRounds = 10
    static let groupRounds = 5

    enum Phase: Equatable { case setup, handOff(Int), pick(Int), reveal, done }

    @State private var phase = Phase.setup
    @State private var count = 1
    @State private var names: [String] = []
    @State private var puzzle: ImpostorPuzzle?
    @State private var next: ImpostorPuzzle?  // fetched while the answer is read
    @State private var picks: [Int?] = []
    @State private var error: String?
    @State private var round = 1
    @State private var scores: [Int] = []
    @State private var streaks: [Int] = []
    private let api = APIClient.fromSettings()

    private var rounds: Int { count == 1 ? Self.soloRounds : Self.groupRounds }
    private var players: [String] { PlayerNames.resolved(names, count: count, first: count == 1 ? "You" : "Player 1") }

    var body: some View {
        VStack(spacing: 0) {
            if phase != .setup { header }
            switch phase {
            case .setup: setup
            case .handOff(let p):
                HandOff(name: players[p], color: PlayerColors.color(p)) { phase = .pick(p) }
            case .pick(let p): puzzleView(picking: p)
            case .reveal: puzzleView(picking: nil)
            case .done: finished
            }
        }
        .animation(.spring(duration: 0.35), value: phase)
    }

    private var header: some View {
        HStack {
            ScorePill(label: "Round", value: "\(min(round, rounds))/\(rounds)", color: .white)
            Spacer()
            if count == 1 {
                if streaks.first ?? 0 > 1 { ScorePill(label: "Streak", value: "\(streaks[0])", color: IconPalette.gold) }
                ScorePill(label: "Score", value: "\(scores.first ?? 0)", color: Game.impostor.color)
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { p in
                        Text("\(scores[p])").font(.caption.weight(.bold).monospacedDigit())
                            .frame(minWidth: 24).padding(.vertical, 4)
                            .background(PlayerColors.color(p).opacity(0.25), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal).padding(.bottom, 8)
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Spot the impostor").font(.system(.title2, design: .serif))
                Text("Four words: three share an ancestor, one only looks like them — or means the same as one. Tap the one that doesn't belong.")
                PlayersSetup(count: $count, names: $names,
                             how: "Each picks in secret on the same four words, passing the phone; then the answer.")
                if let error { Text(error).foregroundStyle(IconPalette.coral) }
                Button {
                    start()
                } label: {
                    Text("Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Game.impostor.color).foregroundStyle(IconPalette.navy)
                .accessibilityIdentifier("impostorStart")
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func puzzleView(picking p: Int?) -> some View {
        if let puzzle {
            ScrollView { board(puzzle, picking: p).padding() }
        } else {
            GameLoading(error: error) { Task { await load() } }
        }
    }

    private func board(_ z: ImpostorPuzzle, picking p: Int?) -> some View {
        VStack(spacing: 14) {
            Text(prompt(z, picking: p))
                .font(.headline)
                .foregroundStyle(p.map(PlayerColors.color) ?? .white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("impostorPrompt")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(z.words.enumerated()), id: \.offset) { i, word in
                    Button { answer(i, by: p ?? 0) } label: { tile(word, i, z, revealed: p == nil) }
                        .buttonStyle(.plain)
                        .disabled(p == nil)
                        .accessibilityIdentifier("impostorWord\(i)")
                }
            }

            if p == nil {
                reveal(z).transition(.opacity.combined(with: .move(edge: .bottom)))
                Button(round >= rounds ? "See scores" : "Next") { advance() }
                    .buttonStyle(.borderedProminent).tint(Game.impostor.color)
                    .disabled(round < rounds && next == nil && error == nil)
                    .accessibilityIdentifier("impostorNext")
            }
        }
    }

    private func prompt(_ z: ImpostorPuzzle, picking p: Int?) -> String {
        if let p {
            return count == 1 ? "Three share an ancestor. Which one doesn't?"
                : "\(players[p]): which one doesn't belong?"
        }
        let odd = z.words[z.impostor].text
        if count == 1 {
            return picks.first == z.impostor ? "Right! “\(odd)” is the impostor." : "Not quite — it was “\(odd)”."
        }
        let right = (0..<count).filter { picks[$0] == z.impostor }.map { players[$0] }
        return "It was “\(odd)”. " + (right.isEmpty ? "Nobody got it!" : "Right: " + right.joined(separator: ", "))
    }

    private func tile(_ word: GameWord, _ i: Int, _ z: ImpostorPuzzle, revealed: Bool) -> some View {
        let odd = i == z.impostor
        let color: Color = !revealed ? .white : odd ? IconPalette.coral : IconPalette.mint
        let pickers = revealed ? (0..<count).filter { picks[$0] == i } : []
        return VStack(spacing: 4) {
            Text(word.text).font(.system(size: 24, design: .serif)).foregroundStyle(.white)
                .minimumScaleFactor(0.4).lineLimit(1).padding(.horizontal, 8)
            Text(revealed ? (odd ? "impostor" : "family") : word.language)
                .font(.caption).foregroundStyle(color.opacity(0.9))
            if !pickers.isEmpty {
                HStack(spacing: 3) {
                    ForEach(pickers, id: \.self) { p in
                        Circle().fill(PlayerColors.color(p)).frame(width: 9)
                    }
                }
                .accessibilityLabel("Picked by " + pickers.map { players[$0] }.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .background(color.opacity(revealed ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(color.opacity(pickers.isEmpty ? 0.35 : 1), lineWidth: pickers.isEmpty ? 1 : 2))
    }

    private func reveal(_ z: ImpostorPuzzle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let root = z.node(z.root) {
                HStack { Spacer(); RootTitle(node: root, size: 26); Spacer() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("The family").font(.caption.weight(.semibold)).foregroundStyle(IconPalette.mint)
                ForEach(Array(z.paths.enumerated()), id: \.offset) { i, path in
                    if i != z.impostor { PathLine(path: path, node: z.node) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(z.why == "means" ? "The impostor means the same, but comes from elsewhere"
                     : "The impostor only looks alike")
                    .font(.caption.weight(.semibold)).foregroundStyle(IconPalette.coral)
                PathLine(path: z.paths[z.impostor], node: z.node)
            }
        }
        .padding(14)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    private var finished: some View {
        ScrollView {
            VStack(spacing: 14) {
                if count == 1 {
                    Text("\(scores.first ?? 0)").font(.system(size: 64, weight: .bold, design: .serif))
                        .foregroundStyle(Game.impostor.color)
                    Text("points in \(rounds) rounds").foregroundStyle(.secondary)
                } else {
                    Leaderboard(names: players, scores: scores)
                }
                HStack {
                    Button("Play again") { start() }
                        .buttonStyle(.borderedProminent).tint(Game.impostor.color)
                    Button("Change players") { phase = .setup }.buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    private func start() {
        round = 1
        scores = Array(repeating: 0, count: count)
        streaks = Array(repeating: 0, count: count)
        puzzle = nil
        next = nil
        newRound()
        Task { await load() }
    }

    private func newRound() {
        picks = Array(repeating: nil, count: count)
        phase = count == 1 ? .pick(0) : .handOff(0)
    }

    private func answer(_ i: Int, by p: Int) {
        picks[p] = i
        if p + 1 < count {
            phase = .handOff(p + 1)
            return
        }
        // everyone has picked: score, show
        guard let z = puzzle else { return }
        for q in 0..<count {
            if picks[q] == z.impostor {
                streaks[q] += 1
                scores[q] += 10 * min(streaks[q], 3)  // 10, 20, then 30 a round on a streak
            } else {
                streaks[q] = 0
            }
        }
        phase = .reveal
        if round < rounds { Task { next = try? await api.impostor(lang: GameLanguage.current) } }
    }

    private func advance() {
        if round >= rounds {
            phase = .done
            return
        }
        round += 1
        if let next {
            puzzle = next
            self.next = nil
        } else {
            puzzle = nil
            Task { await load() }
        }
        newRound()
    }

    private func load() async {
        error = nil
        do {
            puzzle = try await api.impostor(lang: GameLanguage.current)
        } catch {
            self.error = "Couldn't make a puzzle: \(error.localizedDescription)"
        }
    }
}
