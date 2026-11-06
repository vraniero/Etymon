import MapKit
import SwiftData
import SwiftUI

/// The scene as it was when Save was tapped: the camera goes on, the draft doesn't change.
struct SceneDraft: Identifiable {
    let id = UUID()
    let source: String
    let response: SceneResponse
    let language: String?
    let picture: ScenePicture?
}

// MARK: - Save

/// Keep a scene: what it was on (suggested from the picture), where and when, then Save.
struct SaveSceneView: View {
    let draft: SceneDraft
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SaveSettings.locationKey) private var rememberPlace = true

    @State private var object = ""
    @State private var note = ""
    @State private var guesses: [String] = []
    @State private var image: UIImage?
    @State private var place: Locator.Place?
    @State private var locating = false
    @State private var locator = Locator()

    var body: some View {
        NavigationStack {
            Form {
                if let image {
                    Section {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("What was it? A sign, a menu, a book…", text: $object)
                        .accessibilityIdentifier("saveObject")
                    if !guesses.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(guesses, id: \.self) { guess in
                                    Button(guess) { object = guess }
                                        .buttonStyle(.bordered).controlSize(.small)
                                        .tint(object == guess ? .accentColor : .secondary)
                                }
                            }
                        }
                    }
                    TextField("Note", text: $note, axis: .vertical)
                } header: {
                    Text("What")
                }
                Section {
                    LabeledContent("When", value: Date.now.formatted(date: .abbreviated, time: .shortened))
                    Toggle("Remember where", isOn: $rememberPlace)
                    if rememberPlace {
                        LabeledContent("Where") {
                            if locating {
                                ProgressView().controlSize(.small)
                            } else if let place {
                                Text(place.name ?? Self.coordinates(place.coordinate))
                            } else {
                                Text(locator.isDenied ? "Location is off for Etymon" : "Unknown")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("When and where")
                }
                Section {
                    Text(draft.response.words.map(\.text).joined(separator: " · "))
                        .font(.callout)
                } header: {
                    Text("\(draft.response.words.count) words · \(draft.response.connections.count) shared roots · "
                         + "\(draft.response.semanticLinks.count) same meaning")
                }
            }
            .navigationTitle("Save scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("confirmSave")
                }
            }
            .task { await prepare() }
            .onChange(of: rememberPlace) { _, on in
                if on, place == nil { Task { await locate() } }
            }
        }
    }

    private func prepare() async {
        if rememberPlace { Task { await locate() } }
        guard let picture = draft.picture else { return }
        let rendered = await Task.detached(priority: .userInitiated) {
            let image = picture.render(maxSide: 1600)
            let guesses = image?.cgImage.map { ObjectGuess.guesses(for: $0) } ?? []
            return (image, guesses)
        }.value
        image = rendered.0
        guesses = rendered.1
        if object.isEmpty, let first = guesses.first { object = first }
    }

    private func locate() async {
        locating = true
        place = await locator.current()
        locating = false
    }

    private func save() {
        let keep = rememberPlace ? place : nil
        let scene = SavedScene(
            source: draft.source, object: object.trimmingCharacters(in: .whitespaces),
            objectGuesses: guesses, note: note,
            latitude: keep?.coordinate.latitude, longitude: keep?.coordinate.longitude,
            place: keep?.name, language: draft.language, response: draft.response,
            boxes: draft.picture?.boxes ?? [:], pictureSize: image?.size ?? .zero,
            picture: image?.jpegData(compressionQuality: 0.75),
            thumbnail: image?.thumbnail(side: 160)?.jpegData(compressionQuality: 0.7))
        context.insert(scene)
        try? context.save()
        // look up each word's lineage now, while the server is there, for offline use later
        let words = draft.response.words.filter { !$0.terms.isEmpty }
        let client = APIClient.fromSettings()
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for word in words {
                    group.addTask { _ = try? await client.word(word.text, lang: word.lang) }
                }
            }
        }
        dismiss()
    }

    static func coordinates(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }
}

enum SaveSettings {
    static let locationKey = "saveLocation"
}

// MARK: - Library

/// Everything the user has saved: a list (or a map) of scenes, and the network they make
/// together, explorable offline.
struct LibraryView: View {
    @Query(sort: \SavedScene.date, order: .reverse) private var scenes: [SavedScene]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.list
    @State private var search = ""
    @State private var opened: SavedScene?
    @State private var exploreGraph: ExploreGraph?

    enum Mode: String, CaseIterable { case list = "List", map = "Map" }

    private var shown: [SavedScene] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return scenes }
        return scenes.filter { s in
            ([s.object, s.note, s.place ?? ""] + s.words + s.objectGuesses)
                .contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !scenes.isEmpty {
                    Picker("Show", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.bottom, 6)
                }
                if scenes.isEmpty {
                    ContentUnavailableView(
                        "No saved scenes", systemImage: "books.vertical",
                        description: Text("Tap Save under a scene to keep its words, its network, "
                                          + "what it was on, and where and when you found it."))
                } else if mode == .list {
                    list
                } else {
                    map
                }
            }
            .navigationTitle("My network")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Words, objects, places")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Explore all", systemImage: "cube.transparent") { exploreAll() }
                        .disabled(shown.isEmpty)
                        .accessibilityIdentifier("exploreAll")
                }
            }
            .navigationDestination(item: $opened) { SavedSceneView(scene: $0) }
            .fullScreenCover(item: $exploreGraph) { graph in
                ExploreView(graph: graph) { exploreGraph = nil }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(shown) { scene in
                    Button { opened = scene } label: { SavedSceneRow(scene: scene) }
                        .accessibilityIdentifier("savedScene")
                }
                .onDelete { offsets in
                    let doomed = offsets.map { shown[$0] }
                    doomed.forEach(context.delete)
                    try? context.save()
                }
            } footer: {
                let words = Set(shown.flatMap { $0.words.map { $0.lowercased() } }).count
                Text("\(shown.count) scenes · \(words) different words. Explore all joins them "
                     + "into one network, also offline.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var map: some View {
        let located = shown.filter(\.hasLocation)
        return Map(initialPosition: .automatic) {
            ForEach(located) { scene in
                Annotation(scene.title, coordinate: CLLocationCoordinate2D(
                    latitude: scene.latitude!, longitude: scene.longitude!)) {
                    Button { opened = scene } label: {
                        SceneThumbnail(scene: scene, side: 44)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
                            .shadow(radius: 3)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if located.count < shown.count {
                Text("\(shown.count - located.count) scenes saved without a place")
                    .font(.caption).padding(8)
                    .background(.thinMaterial, in: Capsule()).padding()
            }
        }
    }

    /// One network out of all the scenes shown (search narrows it), each scene word
    /// remembering where it was seen.
    private func exploreAll() {
        let merged = SavedNetwork.merge(shown)
        let graph = ExploreGraph(response: merged.response)
        let byID = Dictionary(shown.map { ($0.id, $0) }) { a, _ in a }
        graph.origins = merged.origins.mapValues { ids in
            ids.compactMap { byID[$0].map(SavedSceneRow.summary) }
        }
        exploreGraph = graph
        Task { await Self.joinLineages(graph, words: merged.response.words) }
    }

    /// Link the scenes' words through their lineages: from the server if it is there,
    /// otherwise from what was looked up before (each word's lineage is fetched on save).
    static func joinLineages(_ graph: ExploreGraph, words: [SceneWord]) async {
        let client = APIClient.fromSettings()
        var lineages: [Int: [Step]] = [:]
        var nodes: [String: Node] = [:]
        var done = Set<Int>()
        for word in words {
            guard let term = word.terms.first, done.insert(term).inserted,
                  let found = try? await client.word(word.text, lang: word.lang) else { continue }
            guard let entry = found.entries.first(where: { $0.term == term }) else { continue }
            lineages[term] = entry.lineage
            nodes.merge(found.nodes) { a, _ in a }
        }
        graph.join(lineages: lineages, nodes: nodes)
    }
}

struct SavedSceneRow: View {
    let scene: SavedScene

    var body: some View {
        HStack(spacing: 12) {
            SceneThumbnail(scene: scene, side: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(scene.words.prefix(6).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text([scene.place, scene.date.formatted(date: .abbreviated, time: .shortened)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// "sign · Carrer de Verdi, Barcelona · 5 Nov 2026"
    static func summary(_ scene: SavedScene) -> String {
        [scene.title, scene.place, scene.date.formatted(date: .abbreviated, time: .omitted)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct SceneThumbnail: View {
    let scene: SavedScene
    let side: CGFloat

    var body: some View {
        Group {
            if let data = scene.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: Self.symbol(for: scene.source))
                    .font(.system(size: side * 0.4)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    static func symbol(for source: String) -> String {
        switch source {
        case "Listen": return "waveform"
        case "Type": return "character.cursor.ibeam"
        default: return "text.viewfinder"
        }
    }
}

// MARK: - One saved scene

/// A saved scene as it was: its picture with the network over it (or the graph, for typed
/// and heard words), what it was, where and when. Works without the server.
struct SavedSceneView: View {
    @Bindable var scene: SavedScene
    @State private var model = SceneModel()
    @State private var selection: ContentView.Selection?
    @State private var exploreGraph: ExploreGraph?
    @AppStorage(NetworkLayers.storageKey) private var layers: NetworkLayers = .both

    var body: some View {
        if let response = scene.response {
            content(response)
        } else {
            ContentUnavailableView("Can't read this scene", systemImage: "exclamationmark.triangle")
        }
    }

    private func content(_ response: SceneResponse) -> some View {
        // the picture stays put above the details; tap targets inside list rows misplace
        VStack(spacing: 0) {
            Group {
                if let data = scene.picture, let image = UIImage(data: data) {
                    ZStack {
                        Color.black
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("savedPicture")
                        OverlayView(response: response.showing(layers), model: model, fill: false) {
                            selection = ContentView.Selection.of($0, in: response)
                        }
                    }
                    .clipped()
                } else {
                    NetworkView(response: response.showing(layers), compact: true) {
                        selection = ContentView.Selection.of($0, in: response)
                    }
                }
            }
            .frame(height: 360)
            Picker("Show", selection: $layers) {
                ForEach(NetworkLayers.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 6)
            details(response)
        }
        .navigationTitle(scene.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.show(saved: response, boxes: scene.wordBoxes, imageSize: scene.pictureSize)
        }
        .sheet(item: $selection) { selection in
            NavigationStack {
                switch selection {
                case .connection(let c):
                    ConnectionDetail(connection: c, response: response).navigationTitle("Connection")
                case .word(let text, let lang):
                    WordDetail(text: text, lang: lang)
                case .graph:
                    NetworkView(response: response.showing(layers), compact: true) { key in
                        self.selection = ContentView.Selection.of(key, in: response)
                    }
                    .navigationTitle("Network").navigationBarTitleDisplayMode(.inline)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $exploreGraph) { graph in
            ExploreView(graph: graph) { exploreGraph = nil }
        }
    }

    private func details(_ response: SceneResponse) -> some View {
        List {
            Section {
                HStack {
                    Button("Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                        selection = .graph
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Explore", systemImage: "cube.transparent") {
                        let graph = ExploreGraph(response: response, layers: layers)
                        let summary = SavedSceneRow.summary(scene)
                        graph.origins = Dictionary(graph.sceneWords.map { ($0, [summary]) }) { a, _ in a }
                        exploreGraph = graph
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("exploreSaved")
                }
            }
            Section("What") {
                TextField("What was it?", text: $scene.object)
                TextField("Note", text: $scene.note, axis: .vertical)
            }
            Section("When and where") {
                LabeledContent("When", value: scene.date.formatted(date: .long, time: .shortened))
                if let lat = scene.latitude, let lon = scene.longitude {
                    let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    LabeledContent("Where", value: scene.place ?? SaveSceneView.coordinates(coordinate))
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600))) {
                        Marker(scene.title, coordinate: coordinate)
                    }
                    .frame(height: 160)
                    .listRowInsets(EdgeInsets())
                } else {
                    LabeledContent("Where", value: "Not saved")
                }
                LabeledContent("From", value: scene.source)
                if let lang = scene.language { LabeledContent("Language", value: lang) }
            }
            Section("\(response.words.count) words · \(response.connections.count) shared roots · "
                    + "\(response.semanticLinks.count) same meaning") {
                ForEach(Array(response.words.enumerated()), id: \.offset) { i, word in
                    Button {
                        selection = ContentView.Selection.of(.word(i), in: response)
                    } label: {
                        HStack {
                            Text(word.text).foregroundStyle(.primary)
                            Spacer()
                            if let m = word.meanings?.first {
                                Text(m).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension UIImage {
    /// A square crop from the middle, `side` points across.
    func thumbnail(side: CGFloat) -> UIImage? {
        let scale = side / min(size.width, size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                            width: drawn.width, height: drawn.height))
        }
    }
}
