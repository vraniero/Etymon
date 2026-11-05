import MapKit
import SwiftUI

/// Tree (levels of ancestry) or Map (where each word was spoken). Chosen by the user, remembered.
enum NetworkStyle: String, CaseIterable, Identifiable {
    case tree, map
    static let storageKey = "networkStyle"
    var id: String { rawValue }
    var title: String { self == .tree ? "Tree" : "Map" }
}

/// The network on a world map: every word sits where its language was spoken, and arcs run
/// from each ancestor to its descendant, so the etymological tree is drawn across the land
/// it travelled (Proto-Indo-European on the steppe → Latin in Rome → padre in Italy).
/// Words in the same language share one place. Tapping a word opens its story.
/// Follow: pick a word and travel its line from the leaf back to the root, stop by stop.
struct GeoMapView: View {
    let response: SceneResponse
    var onSelect: (GraphLayout.Key) -> Void

    @State private var position: MapCameraPosition = .automatic
    @State private var journey: Journey?
    @State private var playing = false
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        let geo = GeoLayout(response)
        let route = journey.map(JourneyRoute.init)
        let travelling = journey != nil
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(geo.arcs) { arc in
                MapPolyline(coordinates: arc.points)
                    .stroke(arc.color.opacity(travelling ? 0.15 : 0.85),
                            style: StrokeStyle(lineWidth: arc.isMeaning ? 2 : 2.5, lineCap: .round,
                                               dash: arc.dashed ? [6, 5] : []))
            }
            if !travelling {
                ForEach(geo.arcs.filter { !$0.isMeaning }) { arc in
                    Annotation("", coordinate: arc.arrow, anchor: .center) {
                        Arrow(color: arc.color, angle: arc.angle)
                    }
                    .annotationTitles(.hidden)
                }
            }
            if let route {
                // the way travelled bold, the way ahead faint
                ForEach(route.legs) { leg in
                    MapPolyline(coordinates: leg.arc.points)
                        .stroke(Color.indigo.opacity(leg.travelled ? 0.95 : 0.35),
                                style: StrokeStyle(lineWidth: leg.travelled ? 4.5 : 2.5, lineCap: .round,
                                                   dash: leg.travelled ? [] : [3, 6]))
                }
                ForEach(route.legs.filter(\.travelled)) { leg in
                    Annotation("", coordinate: leg.arc.arrow, anchor: .center) {
                        Arrow(color: .indigo, angle: leg.arc.angle, size: 13)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(geo.places) { place in
                Annotation(place.languages, coordinate: place.coordinate, anchor: .bottom) {
                    PlaceMarker(place: place, response: response,
                                dimmed: travelling && !(route?.visits(place.coordinate) ?? false),
                                onSelect: onSelect)
                }
                .annotationTitles(.hidden)
            }
            if let journey {
                // stops that aren't scene places get a label of their own
                ForEach(Array(journey.stops.enumerated()), id: \.offset) { i, stop in
                    if let point = stop.coordinate, i <= journey.index,
                       !geo.places.contains(where: { GeoLayout.same($0.coordinate, point) }) {
                        Annotation("", coordinate: point, anchor: .center) {
                            JourneyStopLabel(node: stop.node, current: i == journey.index)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            if let here = route?.current {
                Annotation("", coordinate: here, anchor: .center) { JourneyPin() }
                    .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .accessibilityIdentifier("geoMap")
        .onAppear { position = geo.camera }
        .onChange(of: geo.signature) {
            journey = nil
            position = geo.camera
        }
        .onChange(of: journey?.index) {
            guard let journey else { return }
            withAnimation(.easeInOut(duration: 1.1)) { position = journey.camera }
        }
        .task(id: playing) {
            // play: one stop every couple of seconds, until the root
            while playing, let j = journey, !j.isLast {
                try? await Task.sleep(for: .seconds(2.2))
                guard playing, !Task.isCancelled else { return }
                journey?.index += 1
            }
            playing = false
        }
        .overlay(alignment: .topLeading) {
            if !travelling { MapLegend(hasMeanings: geo.arcs.contains(where: \.isMeaning)) }
        }
        .overlay(alignment: .topTrailing) {
            if !travelling { followMenu }
        }
        .overlay(alignment: .bottom) {
            if journey != nil {
                JourneyCard(journey: Binding { journey! } set: { journey = $0 }, playing: $playing,
                            onClose: close, onOpen: { onSelect(.term($0.id)) })
            } else if let problem {
                note(problem).onTapGesture { self.problem = nil }
            } else if !geo.unplaced.isEmpty {
                note("Not on the map: " + geo.unplaced.map { label(for: $0) }.joined(separator: ", "))
            }
        }
    }

    /// Pick a word to follow back to its root.
    private var followMenu: some View {
        Menu {
            Section("Follow a word to its root") {
                ForEach(response.words.indices.filter { !response.words[$0].terms.isEmpty }, id: \.self) { i in
                    Button(response.words[i].text) { follow(i) }
                }
            }
        } label: {
            Group {
                if loading { ProgressView().controlSize(.small) } else { Label("Follow", systemImage: "figure.walk") }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(8)
        .accessibilityIdentifier("journeyMenu")
    }

    private func follow(_ i: Int) {
        problem = nil
        if let j = Journey.fromScene(response, word: i) {
            begin(j)
            return
        }
        // not connected in this scene: fetch the word's own lineage
        let word = response.words[i]
        loading = true
        Task {
            defer { loading = false }
            do {
                let r = try await APIClient.fromSettings().word(word.text, lang: word.lang)
                if let j = Journey.fromWord(r) { begin(j) } else { problem = "No known ancestors for \(word.text)" }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func begin(_ j: Journey) {
        playing = false
        journey = j
        withAnimation(.easeInOut(duration: 1.1)) { position = j.camera }
    }

    private func close() {
        playing = false
        journey = nil
        withAnimation(.easeInOut(duration: 1.1)) { position = GeoLayout(response).camera }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 8)
    }

    private func label(for key: GraphLayout.Key) -> String {
        switch key {
        case .word(let i): return response.words[i].text
        case .term(let id): return response.node(id)?.word ?? "?"
        }
    }
}

/// Direction marker on an arc.
private struct Arrow: View {
    let color: Color
    let angle: Double
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: "arrowtriangle.up.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .rotationEffect(.radians(angle))
    }
}

/// Where everything goes on the map: places (one per language location) and the arcs between them.
struct GeoLayout {
    struct Place: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        var keys: [GraphLayout.Key]
        var languageNames: [String]
        var languages: String { languageNames.joined(separator: " · ") }
    }

    struct Arc: Identifiable {
        let id: String
        let points: [CLLocationCoordinate2D]  // ancestor ... descendant, curved
        let arrow: CLLocationCoordinate2D  // where the direction marker sits
        let angle: Double  // its rotation on screen (the map is Mercator and never rotates)
        let color: Color
        let dashed: Bool
        let isMeaning: Bool
    }

    private(set) var places: [Place] = []
    private(set) var arcs: [Arc] = []
    private(set) var unplaced: [GraphLayout.Key] = []
    /// Changes when the set of places does, to refit the camera.
    private(set) var signature = ""

    init(_ response: SceneResponse) {
        // Every step of every path, plus where each meeting point itself came from.
        let layout = GraphLayout(response, compact: false)
        var wordForTerm: [Int: Int] = [:]
        for (i, w) in response.words.enumerated() {
            for t in w.terms where wordForTerm[t] == nil { wordForTerm[t] = i }
        }
        func key(_ node: Int) -> GraphLayout.Key { wordForTerm[node].map { .word($0) } ?? .term(node) }
        var links = layout.links
        var seen = Set(links)
        for c in response.connections {
            var child = key(c.meet)
            for step in c.deeper {  // deeper starts with the meeting point's parent
                let link = GraphLayout.Link(from: child, to: key(step.node), kind: step.kind)
                if seen.insert(link).inserted { links.append(link) }
                child = link.to
            }
        }

        var keys = Set(layout.items.keys)
        for link in links { keys.insert(link.from); keys.insert(link.to) }
        for i in response.words.indices { keys.insert(.word(i)) }

        func node(for key: GraphLayout.Key) -> Node? {
            switch key {
            case .word(let i): return response.words[i].terms.lazy.compactMap(response.node).first
            case .term(let id): return response.node(id)
            }
        }

        // group by location: Latin, Late Latin and Vulgar Latin all sit in Rome
        var placeOf: [GraphLayout.Key: String] = [:]
        var byId: [String: Place] = [:]
        let ordered = keys.sorted { Self.rank($0, layout) < Self.rank($1, layout) }
        for k in ordered {
            guard let n = node(for: k), let lat = n.lat, let lon = n.lon else {
                if case .word(let i) = k, response.words[i].terms.isEmpty { continue }  // unknown word
                unplaced.append(k)
                continue
            }
            let id = String(format: "%.2f,%.2f", lat, lon)
            placeOf[k] = id
            if byId[id] == nil {
                byId[id] = Place(id: id, coordinate: .init(latitude: lat, longitude: lon),
                                 keys: [], languageNames: [])
            }
            byId[id]!.keys.append(k)
            if !byId[id]!.languageNames.contains(n.language) { byId[id]!.languageNames.append(n.language) }
        }
        places = byId.values.sorted { $0.id < $1.id }
        signature = places.map(\.id).joined(separator: "|")

        // arcs, one per pair of places: older → younger
        var drawn = Set<String>()
        for link in links {
            guard let from = placeOf[link.to], let to = placeOf[link.from], from != to,
                  drawn.insert("\(from)>\(to)").inserted,
                  let a = byId[from]?.coordinate, let b = byId[to]?.coordinate else { continue }
            arcs.append(Self.arc(id: "\(from)>\(to)", from: a, to: b, color: color(for: link.kind),
                                 dashed: link.kind == "borrowed", isMeaning: false))
        }
        for link in response.semanticLinks {
            guard let from = placeOf[.word(link.a)], let to = placeOf[.word(link.b)], from != to,
                  let a = byId[from]?.coordinate, let b = byId[to]?.coordinate else { continue }
            arcs.append(Self.arc(id: "\(from)=\(to)", from: a, to: b, color: .green,
                                 dashed: true, isMeaning: true))
        }
    }

    /// Every place in view, with room around them for the labels above each dot.
    var camera: MapCameraPosition { Self.fit(places.map(\.coordinate)) }

    /// A camera showing all the points, padded for labels above the dots; bottomRoom adds
    /// space below (as a share of the height) for a card over the map.
    static func fit(_ points: [CLLocationCoordinate2D], bottomRoom: Double = 0) -> MapCameraPosition {
        let rects = points.map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
        guard let first = rects.first else { return .automatic }
        let box = rects.dropFirst().reduce(first) { $0.union($1) }
        let side = max(box.width, box.height, MKMapSize.world.width / 40)  // at least a region
        let padX = max(side - box.width, 0) / 2 + side * 0.25
        let padY = max(side - box.height, 0) / 2 + side * 0.3
        let height = box.height + padY * 2.4
        return .rect(MKMapRect(x: box.minX - padX, y: box.minY - padY * 1.4,  // labels sit above dots
                               width: box.width + padX * 2, height: height * (1 + bottomRoom)))
    }

    /// Two coordinates at the same place (as places are grouped).
    static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 0.005 && abs(a.longitude - b.longitude) < 0.005
    }

    /// Scene words first, then meeting points, then the rest oldest-last, so each place lists
    /// what was seen before its ancestors.
    private static func rank(_ key: GraphLayout.Key, _ layout: GraphLayout) -> (Int, Int, Int) {
        let item = layout.items[key]
        switch key {
        case .word(let i): return (0, 0, i)
        case .term(let id): return (item?.isMeeting == true ? 1 : 2, item?.level ?? 99, id)
        }
    }

    /// A curved arc in map space (Mercator), bending to the left of its direction so that
    /// arcs in opposite directions between two places don't overlap.
    static func arc(id: String, from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D,
                            color: Color, dashed: Bool, isMeaning: Bool) -> Arc {
        let p = MKMapPoint(a), q = MKMapPoint(b)
        let dx = q.x - p.x, dy = q.y - p.y
        let bend = isMeaning ? 0.18 : 0.25
        let c = MKMapPoint(x: (p.x + q.x) / 2 + dy * bend, y: (p.y + q.y) / 2 - dx * bend)
        func at(_ t: Double) -> MKMapPoint {
            let u = 1 - t
            return MKMapPoint(x: u * u * p.x + 2 * u * t * c.x + t * t * q.x,
                              y: u * u * p.y + 2 * u * t * c.y + t * t * q.y)
        }
        let points = (0...32).map { at(Double($0) / 32).coordinate }
        // the arrow sits past the middle, pointing along the curve towards the descendant
        let t = 0.6, m = at(t)
        let tx = 2 * (1 - t) * (c.x - p.x) + 2 * t * (q.x - c.x)
        let ty = 2 * (1 - t) * (c.y - p.y) + 2 * t * (q.y - c.y)
        return Arc(id: id, points: points, arrow: m.coordinate, angle: atan2(ty, tx) + .pi / 2,
                   color: color, dashed: dashed, isMeaning: isMeaning)
    }
}

/// The words at one place, with a dot on the exact spot below them.
private struct PlaceMarker: View {
    let place: GeoLayout.Place
    let response: SceneResponse
    var dimmed = false
    var onSelect: (GraphLayout.Key) -> Void

    var body: some View {
        VStack(spacing: 2) {
            if place.keys.count == 1, let key = place.keys.first {
                Button { onSelect(key) } label: { card }.buttonStyle(.plain)
            } else {
                // crowded places (all the Latin forms in Rome) list the rest on tap
                Menu {
                    ForEach(place.keys, id: \.self) { key in
                        Button(title(key)) { onSelect(key) }
                    }
                } label: { card }
                .buttonStyle(.plain)
            }
            Circle().fill(dotColor).frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
        }
        .opacity(dimmed ? 0.3 : 1)
        .animation(.easeInOut, value: dimmed)
    }

    /// The place's main word (a scene word or meeting point first), its language, and how
    /// many more words sit here.
    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if let key = place.keys.first { row(key) }
                if place.keys.count > 1 {
                    Text("+\(place.keys.count - 1)").font(.caption2.bold()).foregroundStyle(.secondary)
                }
            }
            Text(place.languageNames.first ?? "").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: 130, alignment: .leading)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    @ViewBuilder private func row(_ key: GraphLayout.Key) -> some View {
        switch key {
        case .word(let i):
            Text(response.words[i].text).font(.caption.bold())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color(red: 0.84, green: 0.91, blue: 1.0)))
                .foregroundStyle(.black)
        case .term(let id):
            let node = response.node(id)
            let meeting = response.connections.contains { $0.meet == id }
            Text(node?.word ?? "?")
                .font(meeting ? .caption.bold() : .caption)
                .italic(node?.reconstructed ?? false)
                .padding(.horizontal, meeting ? 5 : 0).padding(.vertical, meeting ? 1 : 0)
                .background(Capsule().fill(meeting ? Color(red: 1.0, green: 0.92, blue: 0.62) : .clear))
                .foregroundStyle(meeting ? Color.black : Color.primary)
        }
    }

    private func title(_ key: GraphLayout.Key) -> String {
        switch key {
        case .word(let i): return response.words[i].text
        case .term(let id):
            guard let n = response.node(id) else { return "?" }
            return place.languageNames.count > 1 ? "\(n.word) · \(n.language)" : n.word
        }
    }

    private var dotColor: Color {
        if place.keys.contains(where: { if case .word = $0 { true } else { false } }) { return .blue }
        if place.keys.contains(where: { k in
            if case .term(let id) = k { response.connections.contains { $0.meet == id } } else { false }
        }) { return .orange }
        return .gray
    }
}

private struct MapLegend: View {
    let hasMeanings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ancestor → descendant").font(.caption2.bold())
            HStack(spacing: 8) {
                swatch(.blue, "inherited")
                swatch(.orange, "borrowed")
                if hasMeanings { swatch(.green, "same meaning") }
            }
            Text("proto-language homelands are estimates")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(text).font(.system(size: 9))
        }
    }
}
