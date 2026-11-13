import MapKit
import SwiftUI

/// Birthplace: a word, and a map. Drop a pin where you think it was born — where its
/// oldest known ancestor was spoken — then watch the way it came. Five rounds, up to
/// 5000 points each, fewer the further off.
struct BirthplaceView: View {
    static let rounds = 5

    @State private var puzzle: BirthplacePuzzle?
    @State private var guess: CLLocationCoordinate2D?
    @State private var revealed = false
    @State private var error: String?
    @State private var round = 1
    @State private var total = 0
    @State private var lastPoints = 0
    @State private var done = false
    @State private var camera = MapCameraPosition.region(Self.europe)
    private let api = APIClient.fromSettings()

    static let europe = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46, longitude: 18),
                                           span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 60))

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScorePill(label: "Round", value: "\(min(round, Self.rounds))/\(Self.rounds)", color: .white)
                Spacer()
                ScorePill(label: "Score", value: "\(total)", color: Game.birthplace.color)
            }
            .padding(.horizontal).padding(.bottom, 8)
            if done {
                finished
            } else if let puzzle {
                board(puzzle)
            } else {
                GameLoading(error: error) { Task { await load() } }
            }
        }
        .task { if puzzle == nil { await load() } }
    }

    private func board(_ p: BirthplacePuzzle) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(p.word.text).font(.system(size: 34, design: .serif))
                    .accessibilityIdentifier("birthWord")
                Text(p.word.language).font(.caption).foregroundStyle(Game.birthplace.color)
                Text(revealed ? "" : "Where was it born? Tap the map.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            MapReader { proxy in
                Map(position: $camera) {
                    if let guess {
                        Annotation("Your guess", coordinate: guess) {
                            Image(systemName: "mappin.circle.fill").font(.title)
                                .foregroundStyle(IconPalette.coral)
                        }
                    }
                    if revealed {
                        let stops = journey(p)
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
                    guard !revealed else { return }
                    guess = proxy.convert(point, from: .local)
                }
            }
            bottom(p)
        }
    }

    private func bottom(_ p: BirthplacePuzzle) -> some View {
        VStack(spacing: 8) {
            if revealed, let born = p.node(p.born) {
                Text("Born in \(born.language) as *\(born.word)*\(born.gloss.map { ", “\($0)”" } ?? "")")
                    .multilineTextAlignment(.center)
                if let guess, let lat = born.lat, let lon = born.lon {
                    Text("\(Int(Self.km(guess, CLLocationCoordinate2D(latitude: lat, longitude: lon)))) km off · +\(lastPoints)")
                        .font(.headline).foregroundStyle(Game.birthplace.color)
                }
                Text(journey(p).map { "\($0.0.word) (\($0.0.language))" }.reversed().joined(separator: " → "))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(round >= Self.rounds ? "See score" : "Next word") { advance() }
                    .buttonStyle(.borderedProminent).tint(Game.birthplace.color)
                    .foregroundStyle(IconPalette.navy)
            } else {
                Button("Guess") { reveal(p) }
                    .buttonStyle(.borderedProminent).tint(Game.birthplace.color)
                    .foregroundStyle(IconPalette.navy)
                    .disabled(guess == nil)
                    .accessibilityIdentifier("birthGuess")
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    /// The word and its placed ancestors, back to the birthplace.
    private func journey(_ p: BirthplacePuzzle) -> [(Node, CLLocationCoordinate2D)] {
        p.journey.compactMap { id in
            guard let n = p.node(id), let lat = n.lat, let lon = n.lon else { return nil }
            return (n, CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }

    private func reveal(_ p: BirthplacePuzzle) {
        guard let guess, let born = p.node(p.born), let lat = born.lat, let lon = born.lon else { return }
        let off = Self.km(guess, CLLocationCoordinate2D(latitude: lat, longitude: lon))
        lastPoints = Self.points(km: off)
        withAnimation {
            revealed = true
            total += lastPoints
            let all = journey(p).map(\.1) + [guess]
            camera = .region(Self.region(around: all))
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
        VStack(spacing: 14) {
            Spacer()
            Text("\(total)").font(.system(size: 60, weight: .bold, design: .serif))
                .foregroundStyle(Game.birthplace.color)
            Text("of \(Self.rounds * 5000)").foregroundStyle(.secondary)
            Button("Play again") {
                round = 1; total = 0; done = false
                Task { await load() }
            }
            .buttonStyle(.borderedProminent).tint(Game.birthplace.color).foregroundStyle(IconPalette.navy)
            Spacer()
        }
    }

    private func advance() {
        if round >= Self.rounds { withAnimation { done = true }; return }
        round += 1
        Task { await load() }
    }

    private func load() async {
        error = nil
        puzzle = nil
        guess = nil
        revealed = false
        camera = .region(Self.europe)
        do {
            puzzle = try await api.birthplace(lang: GameLanguage.current)
        } catch {
            self.error = "Couldn't find a word: \(error.localizedDescription)"
        }
    }
}
