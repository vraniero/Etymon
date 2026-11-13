import SwiftUI

/// The word games, opened from the home screen: one list, one language for all of them.
struct GamesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Game]
    @AppStorage(GameLanguage.storageKey) private var language = ""

    init(start: Game? = nil) {
        _path = State(initialValue: start.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    GameLanguagePicker(language: $language)
                        .padding(.bottom, 6)
                    ForEach(Game.allCases) { game in
                        NavigationLink(value: game) { GameCard(game: game) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("game-\(game.rawValue)")
                    }
                }
                .padding(20)
            }
            .gameBackground()
            .navigationTitle("Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("gamesClose")
                }
            }
            .navigationDestination(for: Game.self) { game in
                Group {
                    switch game {
                    case .chain: RootChainView()
                    case .impostor: ImpostorView()
                    case .hunt: HuntView()
                    case .birthplace: BirthplaceView()
                    case .scavenger: ScavengerView()
                    }
                }
                .gameBackground()
                .navigationTitle(game.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

enum Game: String, CaseIterable, Identifiable, Hashable {
    case chain, impostor, hunt, birthplace, scavenger
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chain: "Root Chain"
        case .impostor: "Impostor"
        case .hunt: "Cousin Hunt"
        case .birthplace: "Birthplace"
        case .scavenger: "Scavenger"
        }
    }

    var symbol: String {
        switch self {
        case .chain: "link"
        case .impostor: "theatermasks"
        case .hunt: "timer"
        case .birthplace: "mappin.and.ellipse"
        case .scavenger: "camera.viewfinder"
        }
    }

    var blurb: String {
        switch self {
        case .chain: "Take turns linking words through shared ancestors. Against Etymon or a friend."
        case .impostor: "Four words, three of one family. Spot the one that only looks the part."
        case .hunt: "An ancient root, sixty seconds: name as many of its living descendants as you can."
        case .birthplace: "Where was this word born? Drop a pin, then follow its journey."
        case .scavenger: "Find a word from a given root in the world around you, and photograph it."
        }
    }

    var players: String {
        switch self {
        case .chain: "1–6 players"
        case .impostor, .birthplace, .scavenger: "1–6 players"
        case .hunt: "1–6 players"
        }
    }

    var color: Color {
        switch self {
        case .chain: IconPalette.blue
        case .impostor: IconPalette.coral
        case .hunt: IconPalette.mint
        case .birthplace: IconPalette.sky
        case .scavenger: IconPalette.gold
        }
    }
}

/// The language the games are played in: one of the twenty Etymon reads, or any.
enum GameLanguage {
    static let storageKey = "gameLanguage"

    /// nil: any language.
    static var current: String? {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return stored.isEmpty ? nil : stored
    }

    /// In the phone's language, as elsewhere in the app.
    static func name(_ code: String?) -> String {
        code.map(TalkCaption.name) ?? "Any language"
    }

    /// The twenty, by name.
    static var all: [String] {
        WordExtractor.languages.sorted { name($0) < name($1) }
    }
}

struct GameLanguagePicker: View {
    @Binding var language: String

    var body: some View {
        HStack {
            Label("Language", systemImage: "globe").foregroundStyle(.white.opacity(0.8))
            Spacer()
            Picker("Language", selection: $language) {
                Text("Any language").tag("")
                ForEach(GameLanguage.all, id: \.self) { Text(GameLanguage.name($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(IconPalette.gold)
            .accessibilityIdentifier("gameLanguage")
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct GameCard: View {
    let game: Game

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(game.color.opacity(0.22))
                Circle().strokeBorder(game.color.opacity(0.8), lineWidth: 1.5)
                Image(systemName: game.symbol).font(.title3).foregroundStyle(game.color)
            }
            .frame(width: 46, height: 46)
            .shadow(color: game.color.opacity(0.6), radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(game.title).font(.headline).foregroundStyle(.white)
                    Text(game.players).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(game.color.opacity(0.2), in: Capsule())
                        .foregroundStyle(game.color)
                }
                Text(game.blurb).font(.caption).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(game.color.opacity(0.35)))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: shared by the games

/// One color per player, up to six (Etymon itself plays in gold).
enum PlayerColors {
    static let all = [IconPalette.mint, IconPalette.violet, IconPalette.sky, IconPalette.coral,
                      IconPalette.lavender, IconPalette.blue]
    static func color(_ i: Int) -> Color { all[i % all.count] }
}

/// How many play on one phone, and their names: 1–6.
struct PlayersSetup: View {
    @Binding var count: Int
    @Binding var names: [String]
    /// What several players do, under the stepper.
    let how: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: $count, in: 1...6) {
                Text(count == 1 ? "Solo" : "\(count) players")
            }
            .accessibilityIdentifier("players")
            if count > 1 {
                Text(how).font(.caption).foregroundStyle(.secondary)
                PlayerNames(names: $names, count: count)
            }
        }
    }
}

/// Between two players' turns on one phone: hand it over, the next one taps when ready.
struct HandOff: View {
    let name: String
    let color: Color
    var note = "The others look away!"
    let ready: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 44)).foregroundStyle(color)
            Text("Pass the phone to").foregroundStyle(.secondary)
            Text(name).font(.system(size: 34, design: .serif)).foregroundStyle(color)
            Text(note).font(.caption).foregroundStyle(.secondary)
            Button("I'm \(name) — ready", action: ready)
                .buttonStyle(.borderedProminent).tint(color).foregroundStyle(IconPalette.navy)
                .accessibilityIdentifier("handOffReady")
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

/// Final scores, best first.
struct Leaderboard: View {
    let names: [String]
    let scores: [Int]
    var unit = "points"

    var body: some View {
        let order = scores.indices.sorted { scores[$0] > scores[$1] }
        let best = scores.max() ?? 0
        VStack(spacing: 10) {
            let winners = order.filter { scores[$0] == best }
            Text(winners.count == 1 ? "\(names[winners[0]]) wins" : "A draw")
                .font(.system(.title, design: .serif))
                .accessibilityIdentifier("winner")
            ForEach(order, id: \.self) { p in
                HStack {
                    Circle().fill(PlayerColors.color(p)).frame(width: 10)
                    Text(names[p])
                    Spacer()
                    Text("\(scores[p]) \(unit)").monospacedDigit()
                        .foregroundStyle(PlayerColors.color(p))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

/// Up to six names, one field each, in the player's color.
struct PlayerNames: View {
    @Binding var names: [String]
    let count: Int
    var first = "Player"

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                TextField(i == 0 ? first : "Player \(i + 1)", text: binding(i))
                    .textInputAutocapitalization(.words)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(PlayerColors.color(i).opacity(0.7)))
            }
        }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { i < names.count ? names[i] : "" }, set: { value in
            while names.count <= i { names.append("") }
            names[i] = value
        })
    }

    /// The names typed, or "Player n" where none was.
    static func resolved(_ names: [String], count: Int, first: String = "Player 1") -> [String] {
        (0..<count).map { i in
            let typed = i < names.count ? names[i].trimmingCharacters(in: .whitespaces) : ""
            return typed.isEmpty ? (i == 0 ? first : "Player \(i + 1)") : typed
        }
    }
}

extension View {
    /// The navy field with the icon's tree, faint.
    func gameBackground() -> some View {
        background(RootsBackground(center: CGPoint(x: 0.5, y: 0.2)).opacity(0.18))
            .background(IconPalette.navy)
    }
}

/// A puzzle being fetched, or what went wrong with it.
struct GameLoading: View {
    let error: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let error {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(IconPalette.coral)
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again", action: retry).buttonStyle(.bordered)
            } else {
                ProgressView()
                Text("Digging up a puzzle…").foregroundStyle(.secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Latin pater, “father”": a node as a player reads it.
struct RootTitle: View {
    let node: Node
    var size: CGFloat = 34

    var body: some View {
        VStack(spacing: 4) {
            Text(node.language).font(.subheadline).foregroundStyle(IconPalette.gold)
            Text(node.word).font(.system(size: size, design: .serif)).foregroundStyle(.white)
                .shadow(color: IconPalette.gold.opacity(0.5), radius: 12)
            if let gloss = node.gloss, !gloss.isEmpty {
                Text("“\(gloss)”").font(.callout.italic()).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center).lineLimit(3)
            }
        }
    }
}

/// word → … → root, small.
struct PathLine: View {
    let path: [Int]
    let node: (Int) -> Node?

    var body: some View {
        Text(path.compactMap(node).map { "\($0.word) (\($0.lang))" }.joined(separator: " → "))
            .font(.caption).foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A score in the top corner of a game.
struct ScorePill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(color)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
