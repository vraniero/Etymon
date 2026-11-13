import SwiftUI

/// Impostor: four words, three of one family. Tap the one that only looks the part, then
/// see how the family goes back to its ancestor and where the impostor really comes from.
/// Ten rounds; points for each right answer, more for a streak.
struct ImpostorView: View {
    static let rounds = 10

    @State private var puzzle: ImpostorPuzzle?
    @State private var next: ImpostorPuzzle?  // fetched while the answer is read
    @State private var picked: Int?
    @State private var error: String?
    @State private var round = 1
    @State private var score = 0
    @State private var streak = 0
    @State private var done = false
    private let api = APIClient.fromSettings()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScorePill(label: "Round", value: "\(min(round, Self.rounds))/\(Self.rounds)", color: .white)
                Spacer()
                if streak > 1 { ScorePill(label: "Streak", value: "\(streak)", color: IconPalette.gold) }
                ScorePill(label: "Score", value: "\(score)", color: Game.impostor.color)
            }
            .padding(.horizontal).padding(.bottom, 8)

            if done {
                finished
            } else if let puzzle {
                ScrollView { board(puzzle).padding() }
            } else {
                GameLoading(error: error) { Task { await load() } }
            }
        }
        .task { if puzzle == nil { await load() } }
    }

    private func board(_ p: ImpostorPuzzle) -> some View {
        VStack(spacing: 14) {
            Text(picked == nil ? "Three share an ancestor. Which one doesn't?" : verdict(p))
                .font(.headline)
                .foregroundStyle(picked == nil ? .white : (picked == p.impostor ? IconPalette.mint : IconPalette.coral))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("impostorPrompt")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(p.words.enumerated()), id: \.offset) { i, word in
                    Button { answer(i, p) } label: { tile(word, i, p) }
                        .buttonStyle(.plain)
                        .disabled(picked != nil)
                        .accessibilityIdentifier("impostorWord\(i)")
                }
            }

            if picked != nil {
                reveal(p).transition(.opacity.combined(with: .move(edge: .bottom)))
                Button(round >= Self.rounds ? "See score" : "Next") { advance() }
                    .buttonStyle(.borderedProminent).tint(Game.impostor.color)
                    .disabled(round < Self.rounds && next == nil && error == nil)
                    .accessibilityIdentifier("impostorNext")
            }
        }
    }

    private func tile(_ word: GameWord, _ i: Int, _ p: ImpostorPuzzle) -> some View {
        let revealed = picked != nil
        let odd = i == p.impostor
        let color: Color = !revealed ? .white : odd ? IconPalette.coral : IconPalette.mint
        return VStack(spacing: 4) {
            Text(word.text).font(.system(size: 24, design: .serif)).foregroundStyle(.white)
                .minimumScaleFactor(0.4).lineLimit(1).padding(.horizontal, 8)
            Text(revealed ? (odd ? "impostor" : "family") : word.language)
                .font(.caption).foregroundStyle(color.opacity(0.9))
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .background(color.opacity(revealed ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(color.opacity(picked == i ? 1 : 0.35), lineWidth: picked == i ? 2 : 1))
    }

    private func reveal(_ p: ImpostorPuzzle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let root = p.node(p.root) {
                HStack { Spacer(); RootTitle(node: root, size: 26); Spacer() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("The family").font(.caption.weight(.semibold)).foregroundStyle(IconPalette.mint)
                ForEach(Array(p.paths.enumerated()), id: \.offset) { i, path in
                    if i != p.impostor { PathLine(path: path, node: p.node) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(p.why == "means" ? "The impostor means the same, but comes from elsewhere"
                     : "The impostor only looks alike")
                    .font(.caption.weight(.semibold)).foregroundStyle(IconPalette.coral)
                PathLine(path: p.paths[p.impostor], node: p.node)
            }
        }
        .padding(14)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    private func verdict(_ p: ImpostorPuzzle) -> String {
        picked == p.impostor ? "Right! “\(p.words[p.impostor].text)” is the impostor."
            : "Not quite — it was “\(p.words[p.impostor].text)”."
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("\(score)").font(.system(size: 64, weight: .bold, design: .serif))
                .foregroundStyle(Game.impostor.color)
            Text("points in \(Self.rounds) rounds").foregroundStyle(.secondary)
            Button("Play again") {
                round = 1; score = 0; streak = 0; done = false; puzzle = nil
                Task { await load() }
            }
            .buttonStyle(.borderedProminent).tint(Game.impostor.color)
            Spacer()
        }
    }

    private func answer(_ i: Int, _ p: ImpostorPuzzle) {
        withAnimation(.spring(duration: 0.4)) {
            picked = i
            if i == p.impostor {
                streak += 1
                score += 10 * min(streak, 3)  // 10, 20, then 30 a round on a streak
            } else {
                streak = 0
            }
        }
        if round < Self.rounds { Task { next = try? await api.impostor(lang: GameLanguage.current) } }
    }

    private func advance() {
        if round >= Self.rounds {
            withAnimation { done = true }
            return
        }
        round += 1
        picked = nil
        if let next {
            withAnimation { puzzle = next }
            self.next = nil
        } else {
            puzzle = nil
            Task { await load() }
        }
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
