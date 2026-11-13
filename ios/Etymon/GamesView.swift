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
        case .chain: "1–2 players"
        case .impostor, .birthplace, .scavenger: "Solo"
        case .hunt: "1–2 players"
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

    static func name(_ code: String?) -> String {
        code.map(TalkCaption.name) ?? "Any language"
    }

    /// The twenty, by name.
    static var all: [String] {
        WordExtractor.languages.sorted { TalkCaption.name($0) < TalkCaption.name($1) }
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
                ForEach(GameLanguage.all, id: \.self) { Text(TalkCaption.name($0)).tag($0) }
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
