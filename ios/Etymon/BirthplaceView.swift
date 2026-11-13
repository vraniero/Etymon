import MapKit
import SwiftUI

/// Birthplace: a word, and a map. Drop a pin where you think it was born — where its
/// oldest known ancestor was spoken — then watch the way it came. Five rounds, up to
/// 5000 points each, fewer the further off. Up to six on one phone: each drops a pin in
/// secret, then all are shown together.
struct BirthplaceView: View {
    static let rounds = 5

    enum Phase: Equatable { case setup, handOff(Int), guess(Int), reveal, done }

    @State private var phase = Phase.setup
    @State private var count = 1
    @State private var names: [String] = []
    @State private var puzzle: BirthplacePuzzle?
    @State private var guesses: [CLLocationCoordinate2D?] = []
    @State private var pin: CLLocationCoordinate2D?  // the current player's, before Guess
    @State private var points: [Int] = []  // this round's
    @State private var error: String?
    @State private var round = 1
    @State private var totals: [Int] = []
    @State private var camera = MapCameraPosition.region(Self.europe)
    private let api = APIClient.fromSettings()

    static let europe = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46, longitude: 18),
                                           span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 60))

    private var players: [String] { PlayerNames.resolved(names, count: count, first: count == 1 ? "You" : "Player 1") }

    var body: some View {
        VStack(spacing: 0) {
            if phase != .setup { header }
            switch phase {
            case .setup: setup
            case .handOff(let p):
                HandOff(name: players[p], color: PlayerColors.color(p)) { phase = .guess(p) }
            case .guess(let p): board(guessing: p)
            case .reveal: board(guessing: nil)
            case .done: finished
            }
        }
    }

    private var header: some View {
        HStack {
            ScorePill(label: "Round", value: "\(min(round, Self.rounds))/\(Self.rounds)", color: .white)
            Spacer()
            if count == 1 {
                ScorePill(label: "Score", value: "\(totals.first ?? 0)", color: Game.birthplace.color)
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { p in
                        Text("\(totals[p])").font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 4)
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
                Text("Where was it born?").font(.system(.title2, design: .serif))
                Text("A word, and a map of Europe. Drop a pin where its oldest known ancestor was spoken — then follow the way it came.")
                PlayersSetup(count: $count, names: $names,
                             how: "Each drops a pin in secret on the same word, passing the phone; then all pins are shown.")
                Button { start() } label: {
                    Text("Start").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Game.birthplace.color).foregroundStyle(IconPalette.navy)
                .accessibilityIdentifier("birthStart")
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func board(guessing p: Int?) -> some View {
        if let z = puzzle {
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text(z.word.text).font(.system(size: 34, design: .serif))
                        .accessibilityIdentifier("birthWord")
                    Text(z.word.language).font(.caption).foregroundStyle(Game.birthplace.color)
                    if let p {
                        Text(count == 1 ? "Where was it born? Tap the map." : "\(players[p]): where was it born? Tap the map.")
                            .font(.caption).foregroundStyle(count == 1 ? .secondary : PlayerColors.color(p))
                    }
                }
                .padding(.bottom, 8)
                map(z, guessing: p)
                bottom(z, guessing: p)
            }
        } else {
            GameLoading(error: error) { Task { await load() } }
        }
    }

    private func map(_ z: BirthplacePuzzle, guessing p: Int?) -> some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let p, let pin {
                    Annotation(players[p], coordinate: pin) {
                        Image(systemName: "mappin.circle.fill").font(.title)
                            .foregroundStyle(PlayerColors.color(p))
                    }
                }
                if p == nil {
                    ForEach(0..<count, id: \.self) { q in
                        if let g = guesses[q] {
                            Annotation(count == 1 ? "Your guess" : players[q], coordinate: g) {
                                Image(systemName: "mappin.circle.fill").font(.title)
                                    .foregroundStyle(count == 1 ? IconPalette.coral : PlayerColors.color(q))
                            }
                        }
                    }
                    let stops = journey(z)
                    MapPolyline(coordinates: stops.map(\.1))
                        .stroke(IconPalette.gold, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                    ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                        Annotation("\(stop.0.word) · \(stop.0.language)", coordinate: stop.1) {
                            Circle().fill(i == stops.count - 1 ? IconPalette.gold : Game.birthplace.color)
                                .frame(width: i == stops.count - 1 ? 16 : 10)
                                .shadow(color: IconPalette.gold, radius: 6)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onTapGesture { point in
                guard p != nil else { return }
                pin = proxy.convert(point, from: .local)
            }
        }
    }

    private func bottom(_ z: BirthplacePuzzle, guessing p: Int?) -> some View {
        VStack(spacing: 8) {
            if let p {
                Button("Guess") { guess(p) }
                    .buttonStyle(.borderedProminent).tint(PlayerColors.color(p))
                    .foregroundStyle(IconPalette.navy)
                    .disabled(pin == nil)
                    .accessibilityIdentifier("birthGuess")
            } else if let born = z.node(z.born) {
                Text("Born in \(born.language) as *\(born.word)*\(born.gloss.map { ", “\($0)”" } ?? "")")
                    .multilineTextAlignment(.center)
                ForEach(0..<count, id: \.self) { q in
                    if let g = guesses[q], let lat = born.lat, let lon = born.lon {
                        Text("\(count == 1 ? "" : players[q] + ": ")\(Int(Self.km(g, CLLocationCoordinate2D(latitude: lat, longitude: lon)))) km off · +\(points[q])")
                            .font(count == 1 ? .headline : .subheadline)
                            .foregroundStyle(count == 1 ? Game.birthplace.color : PlayerColors.color(q))
                    }
                }
                Text(journey(z).map { "\($0.0.word) (\($0.0.language))" }.reversed().joined(separator: " → "))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(round >= Self.rounds ? "See scores" : "Next word") { advance() }
                    .buttonStyle(.borderedProminent).tint(Game.birthplace.color)
                    .foregroundStyle(IconPalette.navy)
                    .accessibilityIdentifier("birthNext")
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    /// The word and its placed ancestors, back to the birthplace.
    private func journey(_ z: BirthplacePuzzle) -> [(Node, CLLocationCoordinate2D)] {
        z.journey.compactMap { id in
            guard let n = z.node(id), let lat = n.lat, let lon = n.lon else { return nil }
            return (n, CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }

    private func guess(_ p: Int) {
        guesses[p] = pin
        pin = nil
        camera = .region(Self.europe)
        if p + 1 < count {
            phase = .handOff(p + 1)
        } else {
            reveal()
        }
    }

    private func reveal() {
        guard let z = puzzle, let born = z.node(z.born), let lat = born.lat, let lon = born.lon else { return }
        let target = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        points = guesses.map { $0.map { Self.points(km: Self.km($0, target)) } ?? 0 }
        for q in 0..<count { totals[q] += points[q] }
        withAnimation {
            phase = .reveal
            camera = .region(Self.region(around: journey(z).map(\.1) + guesses.compactMap { $0 }))
        }
    }

    /// 5000 on the spot, half at about 700 km.
    static func points(km: Double) -> Int { Int((5000 * exp(-km / 1000)).rounded()) }

    static func km(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1000
    }

    static func region(around points: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(
            latitudeDelta: max(8, (lats.max()! - lats.min()!) * 1.6),
            longitudeDelta: max(8, (lons.max()! - lons.min()!) * 1.6)))
    }

    private var finished: some View {
        ScrollView {
            VStack(spacing: 14) {
                if count == 1 {
                    Text("\(totals.first ?? 0)").font(.system(size: 60, weight: .bold, design: .serif))
                        .foregroundStyle(Game.birthplace.color)
                    Text("of \(Self.rounds * 5000)").foregroundStyle(.secondary)
                } else {
                    Leaderboard(names: players, scores: totals)
                }
                HStack {
                    Button("Play again") { start() }
                        .buttonStyle(.borderedProminent).tint(Game.birthplace.color)
                        .foregroundStyle(IconPalette.navy)
                    Button("Change players") { phase = .setup }.buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    private func start() {
        round = 1
        totals = Array(repeating: 0, count: count)
        Task { await load() }
        newRound()
    }

    private func newRound() {
        guesses = Array(repeating: nil, count: count)
        points = Array(repeating: 0, count: count)
        pin = nil
        camera = .region(Self.europe)
        phase = count == 1 ? .guess(0) : .handOff(0)
    }

    private func advance() {
        if round >= Self.rounds { phase = .done; return }
        round += 1
        puzzle = nil
        newRound()
        Task { await load() }
    }

    private func load() async {
        error = nil
        puzzle = nil
        do {
            puzzle = try await api.birthplace(lang: GameLanguage.current)
        } catch {
            self.error = "Couldn't find a word: \(error.localizedDescription)"
        }
    }
}
