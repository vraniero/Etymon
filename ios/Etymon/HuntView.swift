import SwiftUI

/// Cousin Hunt: an ancient root, sixty seconds, name as many of its living descendants as
/// you can. Solo, or up to six players on one phone, one after another on the same root.
struct HuntView: View {
    static let seconds = 60

    enum Phase: Equatable { case setup, ready(Int), playing(Int), results }

    @State private var phase = Phase.setup
    static let maxPlayers = 6
    @State private var players = 1
    @State private var names: [String] = []
    @State private var root: GameRoot?
    @State private var error: String?
    @State private var found: [[GameCheck.Found]] = Array(repeating: [], count: Self.maxPlayers)
    @State private var nodes: [Int: Node] = [:]
    @State private var text = ""
    @State private var message: String?
    @State private var checking = false
    @State private var endsAt = Date()
    @FocusState private var typing: Bool
    private let api = APIClient.fromSettings()

    var body: some View {
        Group {
            switch phase {
            case .setup: setup
            case .ready(let p): ready(p)
            case .playing(let p): playing(p)
            case .results: results
            }
        }
        .animation(.spring(duration: 0.4), value: phase)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Name the cousins").font(.system(.title2, design: .serif))
            Text("You'll get an ancient word — Latin *cor*, “heart”. In \(Self.seconds) seconds, type every living word you can think of that comes from it: *core*, *courage*, *cordial*, *corazón*…")
            Stepper(value: $players, in: 1...Self.maxPlayers) {
                Text(players == 1 ? "Solo" : "\(players) players, one after another")
            }
            .accessibilityIdentifier("huntPlayers")
            if players > 1 { PlayerNames(names: $names, count: players) }
            if let error { Text(error).foregroundStyle(IconPalette.coral) }
            Button {
                Task { await newRoot() }
            } label: {
                Text("Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(Game.hunt.color).foregroundStyle(IconPalette.navy)
            .accessibilityIdentifier("huntStart")
            Spacer()
        }
        .padding(20)
    }

    private func ready(_ p: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()
            if let root {
                RootTitle(node: root.root)
                Text("\(root.total)+ descendants in \(GameLanguage.name(GameLanguage.current == nil ? root.lang : GameLanguage.current))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if players > 1 {
                Text("\(name(p)), your turn").font(.headline).foregroundStyle(color(p))
                Text("Pass the phone — the others look away!").font(.caption).foregroundStyle(.secondary)
            }
            Button("Go — \(Self.seconds) seconds") { begin(p) }
                .buttonStyle(.borderedProminent).tint(color(p)).foregroundStyle(IconPalette.navy)
                .accessibilityIdentifier("huntGo")
            Spacer()
        }
        .padding()
    }

    private func playing(_ p: Int) -> some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let left = max(0, endsAt.timeIntervalSince(context.date))
                HStack {
                    ScorePill(label: "Time", value: "\(Int(left.rounded(.up)))s",
                              color: left < 10 ? IconPalette.coral : .white)
                    Spacer()
                    ScorePill(label: players > 1 ? name(p) : "Found",
                              value: "\(found[p].count)", color: color(p))
                }
                .onChange(of: left == 0) { _, over in if over { finish(p) } }
            }
            .padding(.horizontal)
            if let root { RootTitle(node: root.root, size: 28).padding(.vertical, 10) }
            ScrollView {
                FlowChips(words: found[p].map(\.text), color: color(p))
                    .padding(.horizontal)
            }
            VStack(spacing: 6) {
                if let message {
                    Text(message).font(.callout).foregroundStyle(IconPalette.coral)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    TextField("A descendant", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).focused($typing)
                        .onSubmit { submit(p) }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("huntWord")
                    if checking { ProgressView() }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .onAppear { typing = true }
    }

    private var results: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let root { RootTitle(node: root.root, size: 28) }
                ForEach(0..<players, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(players > 1 ? "\(name(p)): \(found[p].count)" : "You found \(found[p].count)")
                            .font(.headline).foregroundStyle(color(p))
                        ForEach(found[p], id: \.self) { f in
                            PathLine(path: f.path) { nodes[$0] }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if players > 1 {
                    Text(verdict).font(.system(.title, design: .serif))
                        .multilineTextAlignment(.center)
                }
                if let root {
                    let all = Set(found.flatMap { $0.map { $0.text.lowercased() } })
                    let missed = root.examples.filter { !all.contains($0.lowercased()) }
                    if !missed.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Some you could have said").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            FlowChips(words: missed, color: .white.opacity(0.6))
                        }
                    }
                }
                HStack {
                    Button("New root") { Task { await newRoot() } }
                        .buttonStyle(.borderedProminent).tint(Game.hunt.color)
                        .foregroundStyle(IconPalette.navy)
                    Button("Change players") { phase = .setup }.buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    private func color(_ p: Int) -> Color { PlayerColors.color(p) }

    private func name(_ p: Int) -> String { PlayerNames.resolved(names, count: players)[p] }

    /// Who found the most; a draw between the best when tied.
    private var verdict: String {
        let best = (0..<players).map { found[$0].count }.max() ?? 0
        let top = (0..<players).filter { found[$0].count == best }
        return top.count == 1 ? "\(name(top[0])) wins"
            : "A draw: " + top.map(name).joined(separator: ", ")
    }

    private func newRoot() async {
        error = nil
        do {
            root = try await api.gameRoot(lang: GameLanguage.current)
            found = Array(repeating: [], count: Self.maxPlayers)
            nodes = [:]
            phase = .ready(0)
        } catch {
            self.error = "Couldn't find a root: \(error.localizedDescription)"
            phase = .setup
        }
    }

    private func begin(_ p: Int) {
        message = nil
        text = ""
        endsAt = Date().addingTimeInterval(TimeInterval(Self.seconds))
        phase = .playing(p)
    }

    private func finish(_ p: Int) {
        guard phase == .playing(p) else { return }
        typing = false
        phase = p + 1 < players ? .ready(p + 1) : .results
    }

    private func submit(_ p: Int) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, let root, endsAt > Date() else { return }
        text = ""
        typing = true
        if found[p].contains(where: { $0.text.lowercased() == word.lowercased() }) {
            message = "You have “\(word)” already."
            return
        }
        checking = true
        Task {
            defer { checking = false }
            do {
                let lang = GameLanguage.current
                let check = try await api.check(root: root.root.id, words: [word], lang: lang)
                for (k, n) in check.nodes { if let id = Int(k) { nodes[id] = n } }
                if let hit = check.found.first {
                    // same word in another form (cuori after cuore) counts once
                    if found[p].contains(where: { $0.path.first == hit.path.first }) {
                        message = "That's a form of one you have."
                    } else {
                        withAnimation { found[p].append(hit) }
                        message = nil
                    }
                } else if !check.unknown.isEmpty {
                    message = "Etymon doesn't know “\(word)”."
                } else {
                    message = "“\(word)” doesn't come from \(root.root.word)."
                }
            } catch {
                message = "Can't reach the server."
            }
        }
    }
}

/// Words as chips that wrap onto new lines.
struct FlowChips: View {
    let words: [String]
    let color: Color

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                Text(w).font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(color.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(color.opacity(0.5)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}
