import MapKit
import SwiftUI

/// Following one word back in time on the map, stop by stop: from the word seen (the leaf)
/// through each ancestor to the oldest known root. padre (Italy) → patre → pater (Rome) →
/// *patēr (Proto-Italic) → *ph₂tḗr (the steppe).
struct Journey: Equatable {
    struct Stop: Hashable {
        let node: Node
        let kind: String?  // how the previous stop came from this one; nil for the leaf

        var coordinate: CLLocationCoordinate2D? {
            guard let lat = node.lat, let lon = node.lon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    let word: String
    let stops: [Stop]
    var index = 0

    var stop: Stop { stops[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == stops.count - 1 }

    /// The word's line in the scene: its path to the ancestor it shares with another word,
    /// then that ancestor's own line upward. The longest such line wins. nil if the word has
    /// no connection in the scene.
    static func fromScene(_ response: SceneResponse, word i: Int) -> Journey? {
        var best: [Step] = []
        for c in response.connections where c.a == i || c.b == i {
            let path = (c.a == i ? c.pathA : c.pathB) + c.deeper  // deeper starts above meet
            if path.count > best.count { best = path }
        }
        let stops = best.compactMap { s in response.node(s.node).map { Stop(node: $0, kind: s.kind) } }
        return stops.count > 1 ? Journey(word: response.words[i].text, stops: stops) : nil
    }

    /// A word's own lineage, from GET /word.
    static func fromWord(_ response: WordResponse) -> Journey? {
        guard let entry = response.entries.max(by: { $0.lineage.count < $1.lineage.count }) else {
            return nil
        }
        let steps = [Step(node: entry.term, kind: nil)] + entry.lineage
        let stops = steps.compactMap { s in response.node(s.node).map { Stop(node: $0, kind: s.kind) } }
        return stops.count > 1 ? Journey(word: response.text, stops: stops) : nil
    }

    /// The nearest stop at or before i that has a place on the map.
    func placed(atOrBefore i: Int) -> Int? {
        stride(from: min(i, stops.count - 1), through: 0, by: -1).first { stops[$0].coordinate != nil }
    }

    /// What the camera should show at the current stop: where we came from and where we are.
    var camera: MapCameraPosition {
        guard let here = placed(atOrBefore: index), let point = stops[here].coordinate else {
            return .automatic
        }
        let previous = here > 0 ? placed(atOrBefore: here - 1).flatMap { stops[$0].coordinate } : nil
        return GeoLayout.fit([point] + (previous.map { [$0] } ?? []), bottomRoom: 0.9)
    }
}

/// The journey drawn on the map: one leg per move between places, younger → older.
struct JourneyRoute {
    struct Leg: Identifiable {
        let id: Int  // index of the stop the leg arrives at
        let arc: GeoLayout.Arc
        let travelled: Bool
    }

    let legs: [Leg]
    let current: CLLocationCoordinate2D?
    let visited: [CLLocationCoordinate2D]

    init(_ journey: Journey) {
        var legs: [Leg] = [], visited: [CLLocationCoordinate2D] = []
        var last: CLLocationCoordinate2D?
        for (i, stop) in journey.stops.enumerated() {
            guard let point = stop.coordinate else { continue }
            if i <= journey.index { visited.append(point) }
            if let from = last, !GeoLayout.same(from, point) {
                legs.append(Leg(id: i, arc: GeoLayout.arc(id: "j\(i)", from: from, to: point,
                                                          color: .indigo, dashed: false,
                                                          isMeaning: false),
                                travelled: i <= journey.index))
            }
            last = point
        }
        self.legs = legs
        self.visited = visited
        current = journey.placed(atOrBefore: journey.index).flatMap { journey.stops[$0].coordinate }
    }

    func visits(_ coordinate: CLLocationCoordinate2D) -> Bool {
        visited.contains { GeoLayout.same($0, coordinate) }
    }
}

/// Where we are on the journey, and the controls to move along it.
struct JourneyCard: View {
    @Binding var journey: Journey
    @Binding var playing: Bool
    var onClose: () -> Void
    var onOpen: (Node) -> Void

    var body: some View {
        let stop = journey.stop
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(journey.isFirst ? "The word you saw" : journey.isLast ? "Oldest known root"
                     : "Step \(journey.index) of \(journey.stops.count - 1)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.indigo)
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .accessibilityIdentifier("journeyClose")
            }
            if !journey.isFirst {
                let previous = journey.stops[journey.index - 1].node
                Text("\(previous.word) \(relation(stop.kind))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(stop.node.word).font(.title3.bold()).italic(stop.node.reconstructed)
                Text(stop.node.language).font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            if let gloss = stop.node.gloss, !gloss.isEmpty {
                Text(gloss).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if stop.coordinate == nil {
                Text("No place known for this language").font(.caption2).foregroundStyle(.orange)
            }
            ProgressView(value: Double(journey.index), total: Double(max(journey.stops.count - 1, 1)))
                .tint(.indigo)
            HStack(spacing: 18) {
                Button("Back", systemImage: "chevron.backward") { move(-1) }
                    .disabled(journey.isFirst)
                    .accessibilityIdentifier("journeyBack")
                Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                    if journey.isLast { journey.index = 0 }
                    playing.toggle()
                }
                .accessibilityIdentifier("journeyPlay")
                Button("Forward", systemImage: "chevron.forward") { move(1) }
                    .disabled(journey.isLast)
                    .accessibilityIdentifier("journeyForward")
                Spacer()
                Button("Story", systemImage: "info.circle") { onOpen(stop.node) }
                    .labelStyle(.titleAndIcon).font(.caption)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
    }

    private func move(_ by: Int) {
        playing = false
        journey.index = min(max(journey.index + by, 0), journey.stops.count - 1)
    }

    private func relation(_ kind: String?) -> String {
        switch kind {
        case "root": return "goes back to the root"
        case nil: return "from"
        default:
            let d = describe(kind: kind)
            return d.isEmpty ? "from" : d
        }
    }
}

/// The traveller's position: a pulsing dot.
struct JourneyPin: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(Color.indigo.opacity(0.25)).frame(width: 34, height: 34)
                .scaleEffect(pulse ? 1.2 : 0.7)
            Circle().fill(Color.indigo).frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .allowsHitTesting(false)
    }
}

/// A label for a journey stop that isn't one of the scene's places (lineages fetched for words
/// with no connection).
struct JourneyStopLabel: View {
    let node: Node
    let current: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(node.word).font(current ? .caption.bold() : .caption2).italic(node.reconstructed)
            Text(node.language).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(.regularMaterial))
        .offset(y: -22)
    }
}
