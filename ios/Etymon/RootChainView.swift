import SwiftUI

/// Root Chain: pick an opponent, then play. In Games.
struct RootChainView: View {
    @State private var game: ChainGame?
    @State private var setup = ChainSetup()
    @State private var starting = false
    @State private var error: String?
    @AppStorage(GameLanguage.storageKey) private var language = ""

    var body: some View {
        Group {
            if let game {
                ChainBoard(game: game, onAgain: { start() }, onNew: { self.game = nil })
            } else {
                ChainSetupView(setup: $setup, language: $language, starting: starting,
                               error: error, onStart: start)
            }
        }
    }

    /// Opening word: one of the starters in English (or any language), else one the
    /// backend picks in the game's language.
    private func start() {
        let names = PlayerNames.resolved(setup.names, count: setup.people,
                                         first: setup.vsApp && setup.people == 1 ? "You" : "Player 1")
        let lang = GameLanguage.current
        starting = true
        error = nil
        Task {
            defer { starting = false }
            var word = LaunchOptions.value(after: "-chainStart")
                ?? (lang == nil || lang == "en" ? ChainRules.starters.randomElement()! : nil)
            var wordLang = lang ?? "en"
            if word == nil, let lang {
                do {
                    let opening = try await APIClient.fromSettings().chainStart(lang: lang)
                    word = opening.text
                    wordLang = opening.lang
                } catch {
                    self.error = "Couldn't find an opening word: \(error.localizedDescription)"
                    return
                }
            }
            let game = ChainGame(opponent: setup.vsApp ? .app(setup.level) : .friend, names: names,
                                 start: word!, startLang: wordLang, language: lang)
            withAnimation { self.game = game }
            await game.prepare()
        }
    }
}

struct ChainSetup {
    var vsApp = true
    var level = ChainLevel.easy
    var names: [String] = []
    private var chosen = 1  // people on the phone, as last set

    /// People taking turns on the phone: 1–5 with Etymon, 2–6 without.
    var people: Int {
        get { min(max(chosen, range.lowerBound), range.upperBound) }
        set { chosen = newValue }
    }
    var range: ClosedRange<Int> {
        vsApp ? 1...(ChainGame.maxPlayers - 1) : 2...ChainGame.maxPlayers
    }
}

private struct ChainSetupView: View {
    @Binding var setup: ChainSetup
    @Binding var language: String
    let starting: Bool
    let error: String?
    let onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                rules
                Picker("Opponent", selection: $setup.vsApp) {
                    Text("Against Etymon").tag(true)
                    Text("Pass and play").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("chainOpponent")

                if setup.vsApp {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Level", selection: $setup.level) {
                            ForEach(ChainLevel.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(setup.level.blurb).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $setup.people, in: setup.range) {
                    Text(setup.vsApp ? "\(setup.people) \(setup.people == 1 ? "person" : "people") + Etymon"
                         : "\(setup.people) players")
                }
                .accessibilityIdentifier("chainPlayers")
                if setup.people > 1 || !setup.vsApp {
                    PlayerNames(names: $setup.names, count: setup.people)
                }

                GameLanguagePicker(language: $language)

                if let error {
                    Text(error).font(.callout).foregroundStyle(IconPalette.coral)
                }
                Button(action: onStart) {
                    Group {
                        if starting { ProgressView().tint(IconPalette.navy) } else { Text("Start") }
                    }
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .disabled(starting)
                .buttonStyle(.borderedProminent)
                .tint(IconPalette.gold)
                .foregroundStyle(IconPalette.navy)
                .accessibilityIdentifier("chainStart")
            }
            .padding(20)
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep the chain growing")
                .font(.system(.title2, design: .serif))
            Text(language.isEmpty
                 ? "Take turns adding a word, in any language, that shares an ancestor with the last one: *father* → *padre* → *paternal*."
                 : "Take turns adding a word in \(GameLanguage.name(language)) that shares an ancestor with the last one.")
            VStack(alignment: .leading, spacing: 6) {
                Label("Not through the same ancestor as the link before", systemImage: "arrow.triangle.branch")
                Label("No word played twice, in any form", systemImage: "repeat")
                Label(language.isEmpty ? "+1 a link, +1 a new language, +1 an ancient root"
                      : "+1 a link, +1 an ancient root", systemImage: "star")
                Label("First to \(ChainRules.target) wins — \(ChainRules.lives) misses and you're out", systemImage: "heart")
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// The game: scores at the top, the chain in the middle, the next word at the bottom.
private struct ChainBoard: View {
    let game: ChainGame
    let onAgain: () -> Void
    let onNew: () -> Void
    @State private var text = ""
    @State private var opened: UUID?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            scores.padding(.horizontal).padding(.bottom, 8)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(game.moves.enumerated()), id: \.element.id) { i, move in
                            if move.link != nil {
                                LinkRow(move: move, color: color(of: move),
                                        open: opened == move.id) {
                                    withAnimation { opened = opened == move.id ? nil : move.id }
                                }
                            }
                            WordCard(move: move, color: color(of: move), isLast: i == game.moves.count - 1)
                                .id(move.id)
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: game.moves.count) {
                    withAnimation { reader.scrollTo(game.last.id, anchor: .bottom) }
                }
                .onChange(of: game.turn) {
                    if !game.current.isApp && !game.isOver { typing = true }
                }
            }
            if game.isOver { result } else { input }
        }
    }

    private func color(of move: ChainMove) -> Color {
        move.player.map { game.players[$0].color } ?? .white
    }

    /// Two players side by side; more in rows of three, smaller.
    private var scores: some View {
        let compact = game.players.count > 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                        count: compact ? 3 : 2), spacing: 8) {
            ForEach(game.players) { player in
                let active = player.id == game.turn && !game.isOver
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(player.name).font((compact ? Font.caption : .subheadline).weight(.semibold))
                            .lineLimit(1)
                            .strikethrough(player.isOut)
                        Spacer(minLength: 2)
                        HStack(spacing: 2) {
                            ForEach(0..<ChainRules.lives, id: \.self) { i in
                                Image(systemName: i < player.lives ? "heart.fill" : "heart")
                                    .font(.system(size: compact ? 8 : 11))
                                    .foregroundStyle(i < player.lives ? IconPalette.coral : .white.opacity(0.3))
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(player.score)").font((compact ? Font.headline : .title2).weight(.bold).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("/ \(ChainRules.target)").font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(min(player.score, ChainRules.target)),
                                 total: Double(ChainRules.target))
                        .tint(player.color)
                }
                .padding(compact ? 7 : 10)
                .opacity(player.isOut ? 0.45 : 1)
                .background(player.color.opacity(active ? 0.22 : 0.06), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(player.color.opacity(active ? 0.9 : 0.2), lineWidth: active ? 1.5 : 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(player.name): \(player.score) points, \(player.lives) lives\(active ? ", to play" : "")")
            }
        }
        .animation(.spring(duration: 0.4), value: game.turn)
    }

    private var input: some View {
        VStack(spacing: 8) {
            if let message = game.message {
                Text(message).font(.callout).foregroundStyle(IconPalette.coral)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chainMessage")
            }
            // The field stays put whoever's turn it is (swapping it out for Etymon's turn
            // once left the screen stuck on "thinking"); only the line above it changes.
            let appTurn = game.current.isApp
            HStack(spacing: 8) {
                if appTurn { ProgressView().controlSize(.small) }
                Text(appTurn ? "Etymon is thinking…"
                     : "\(game.current.name), a word linked to “\(game.last.text)”")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chainTurn")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                TextField(GameLanguage.name(game.language), text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($typing)
                    .onSubmit(submit)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(game.current.color.opacity(0.7)))
                    .disabled(appTurn)
                    .accessibilityIdentifier("chainWord")
                Button(action: submit) {
                    if game.busy && !appTurn { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title) }
                }
                .tint(game.current.color)
                .disabled(appTurn || game.busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Play").accessibilityIdentifier("chainPlay")
                Button("Pass") { game.pass() }
                    .buttonStyle(.bordered)
                    .disabled(appTurn || game.busy)
                    .accessibilityIdentifier("chainPass")
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func submit() {
        let word = text
        Task {
            await game.play(word)
            if game.moves.last?.text.lowercased() == word.trimmingCharacters(in: .whitespaces).lowercased() {
                text = ""
            }
            // pass and play: the phone changes hands, keep the keyboard
            if !game.current.isApp { typing = true }
        }
    }

    private var result: some View {
        let winner = game.winner.map { game.players[$0] }
        return VStack(spacing: 12) {
            if let message = game.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Text(winner.map { $0.isApp ? "Etymon wins" : "\($0.name) wins!" } ?? "")
                .font(.system(.title, design: .serif))
                .foregroundStyle(winner?.color ?? .white)
                .accessibilityIdentifier("chainWinner")
            Text("A chain of \(game.moves.count) words").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Play again", action: onAgain).buttonStyle(.borderedProminent).tint(IconPalette.gold)
                    .foregroundStyle(IconPalette.navy)
                Button("Change players", action: onNew).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial)
    }
}

private struct WordCard: View {
    let move: ChainMove
    let color: Color
    let isLast: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let note = move.note {
                Text(note).font(.caption).foregroundStyle(IconPalette.coral)
                    .padding(.top, 14)
            }
            card
        }
    }

    private var card: some View {
        VStack(spacing: 2) {
            Text(move.text)
                .font(.system(size: isLast ? 30 : 24, weight: .regular, design: .serif))
                .foregroundStyle(.white)
            Text(move.language ?? move.lang ?? "")
                .font(.caption).foregroundStyle(color.opacity(0.9))
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(color.opacity(isLast ? 0.2 : 0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(isLast ? 0.9 : 0.4), lineWidth: isLast ? 1.5 : 1))
        .shadow(color: color.opacity(isLast ? 0.6 : 0), radius: 14)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

/// Between two words: where they meet. Tapped, the two lines up to that ancestor.
private struct LinkRow: View {
    let move: ChainMove
    let color: Color
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        if let link = move.link, let scene = move.scene {
            let meet = scene.node(link.meet)
            Button(action: toggle) {
                VStack(spacing: 6) {
                    Rectangle().fill(LinearGradient(colors: [.white.opacity(0.3), color],
                                                    startPoint: .top, endPoint: .bottom))
                        .frame(width: 2, height: 14)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.merge").foregroundStyle(IconPalette.gold)
                        Text(meet.map { "\($0.language) \($0.word)" } ?? "a shared ancestor")
                            .font(.callout.italic())
                            .foregroundStyle(IconPalette.cream)
                        if let gloss = meet?.gloss, !gloss.isEmpty {
                            Text("“\(gloss)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text("+\(move.points)")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(color.opacity(0.3), in: Capsule())
                    }
                    if open {
                        VStack(alignment: .leading, spacing: 4) {
                            line(link.pathA, in: scene)
                            line(link.pathB, in: scene)
                        }
                        .font(.caption)
                        .padding(10)
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        .transition(.opacity)
                    }
                    Rectangle().fill(color).frame(width: 2, height: 14)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Linked through \(meet?.language ?? "") \(meet?.word ?? ""), \(move.points) points")
            .accessibilityHint("Shows how the two words reach it")
        }
    }

    /// word → its ancestors → the meeting point.
    private func line(_ path: [Step], in scene: SceneResponse) -> some View {
        let words = path.compactMap { step in scene.node(step.node).map { "\($0.word) (\($0.lang))" } }
        return Text(words.joined(separator: " → ")).foregroundStyle(.white.opacity(0.85))
    }
}
