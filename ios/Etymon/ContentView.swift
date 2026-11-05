import PhotosUI
import SwiftUI

struct ContentView: View {
    enum Source: String, CaseIterable, Identifiable {
        case camera = "Camera", photo = "Photo", type = "Type"
        var id: String { rawValue }
    }

    enum Selection: Identifiable {
        case connection(Connection)
        case word(text: String, lang: String?)
        case graph
        var id: String {
            switch self {
            case .connection(let c): return "c\(c.id)"
            case .word(let t, let l): return "w\(t)\(l ?? "")"
            case .graph: return "graph"
            }
        }
    }

    @State private var model = SceneModel()
    @State private var source: Source = LaunchOptions.source
        ?? (CameraScanner.isAvailable ? .camera : .type)
    @State private var selection: Selection?
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var fullPaths = false
    @State private var exploreGraph: ExploreGraph?  // set = Explore is open
    @AppStorage(NetworkLayers.storageKey) private var layers: NetworkLayers = .both
    @AppStorage(SearchDepth.storageKey) private var searchDepth = SearchDepth.defaultValue
    @AppStorage(WordLimit.storageKey) private var maxWords = WordLimit.defaultValue

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 8)
                .onChange(of: source) { model.reset() }

                switch source {
                case .camera:
                    CameraInput(model: model, layers: layers, exploring: exploreGraph != nil,
                                onSelect: select, onExplore: explore)
                    status
                case .photo:
                    PhotoInput(model: model, layers: layers, onSelect: select)
                    status
                case .type:
                    TypeInput(model: model).frame(height: 130)
                    status
                    if model.response != nil { layersPicker }
                    graph
                }
            }
            .navigationTitle("Etymon")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: searchDepth) { model.refresh() }
            .onChange(of: maxWords) { model.applyWordLimit() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", systemImage: "trash") { model.reset() }
                        .disabled(model.words.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Help", systemImage: "questionmark.circle") { showHelp = true }
                        .accessibilityIdentifier("help")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gear") { showSettings = true }
                }
            }
            .sheet(item: $selection) { selection in
                NavigationStack {
                    switch selection {
                    case .connection(let c):
                        if let response = model.response {
                            ConnectionDetail(connection: c, response: response)
                                .navigationTitle("Connection")
                        }
                    case .word(let text, let lang):
                        WordDetail(text: text, lang: lang)
                    case .graph:
                        VStack(spacing: 0) {
                            layersPicker
                            Toggle("Full paths", isOn: $fullPaths).padding(.horizontal)
                                .disabled(!layers.showsRoots)
                            graph
                        }
                        .navigationTitle("Network")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHelp) { HelpView() }
            .fullScreenCover(item: $exploreGraph) { graph in
                ExploreView(graph: graph) { exploreGraph = nil }
            }
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            if model.isLoading { ProgressView().controlSize(.small) }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if model.words.isEmpty {
                Text(source == .camera ? "Point at some text." :
                     source == .photo ? "Pick a photo with some text." : "Type a few words.")
            } else {
                let roots = model.response?.connections.count ?? 0
                let meanings = model.response?.semanticLinks.count ?? 0
                Text("\(model.words.count) words · \(roots) shared roots · \(meanings) same meaning"
                     + (model.language.map { " · \($0)" } ?? ""))
            }
            Spacer()
            if source != .type, model.response != nil {
                Menu {
                    Picker("Show", selection: $layers) {
                        ForEach(NetworkLayers.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(layers.title, systemImage: "square.3.layers.3d")
                }
                .controlSize(.mini).buttonStyle(.bordered)
                .accessibilityIdentifier("layersMenu")
            }
            if source == .type, layers.showsRoots, model.response?.connections.isEmpty == false {
                Toggle("Full paths", isOn: $fullPaths)
                    .toggleStyle(.button).controlSize(.mini)
                    .accessibilityIdentifier("fullPaths")
            } else if source != .type, model.response != nil {
                Button("Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                    selection = .graph
                }
                .controlSize(.mini).buttonStyle(.bordered)
                .accessibilityIdentifier("showGraph")
            }
            if source != .camera, model.response?.words.isEmpty == false {
                Button("Explore", systemImage: "cube.transparent") { explore() }
                    .controlSize(.mini).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("explore")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal).padding(.vertical, 6)
    }

    /// Shared roots, same meanings, or both side by side.
    private var layersPicker: some View {
        Picker("Show", selection: $layers) {
            ForEach(NetworkLayers.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal).padding(.vertical, 4)
        .accessibilityIdentifier("layersPicker")
    }

    @ViewBuilder private var graph: some View {
        if let response = model.response, !response.words.isEmpty {
            NetworkView(response: response.showing(layers), compact: !fullPaths, onSelect: select)
        } else {
            Spacer()
        }
    }

    /// Leave the picture for the word network behind it, in 3D.
    private func explore() {
        guard let response = model.response else { return }
        exploreGraph = ExploreGraph(response: response, layers: layers)
    }

    private func select(_ key: GraphLayout.Key) {
        guard let response = model.response else { return }
        switch key {
        case .word(let i):
            // a word that is a meeting point (caffè for coffee) shows the connection
            if let c = response.connections.first(where: { response.words[i].terms.contains($0.meet) }) {
                selection = .connection(c)
            } else {
                selection = .word(text: response.words[i].text, lang: response.words[i].lang)
            }
        case .term(let id):
            if let c = response.connections.first(where: { $0.meet == id }) {
                selection = .connection(c)
            } else if let n = response.node(id) {
                selection = .word(text: n.word, lang: n.lang)
            }
        }
    }
}

/// Live video with the network drawn over it, following the words as the camera moves.
private struct CameraInput: View {
    let model: SceneModel
    let layers: NetworkLayers
    let exploring: Bool
    var onSelect: (GraphLayout.Key) -> Void
    var onExplore: () -> Void
    @State private var scanner = CameraScanner()
    @State private var paused = false

    var body: some View {
        if CameraScanner.isAvailable {
            ZStack(alignment: .bottomTrailing) {
                CameraPreview(session: scanner.session)
                if let response = model.response {
                    OverlayView(response: response.showing(layers), model: model, fill: true,
                                onSelect: onSelect)
                }
                HStack {
                    Button(paused ? "Collect" : "Hold", systemImage: paused ? "plus.viewfinder" : "pause.fill") {
                        paused.toggle()
                        scanner.isPaused = paused  // still tracks positions, stops adding words
                    }
                    .buttonStyle(.borderedProminent)
                    // Explore: the video stops, the network behind it opens in 3D
                    Button("Explore", systemImage: "cube.transparent", action: onExplore)
                        .buttonStyle(.borderedProminent).tint(.indigo)
                        .disabled(model.response?.words.isEmpty ?? true)
                        .accessibilityIdentifier("explore")
                }
                .padding(12)
            }
            .clipped()
            .onChange(of: exploring) { _, isExploring in
                if isExploring { scanner.stop() } else { scanner.start() }
            }
            .onAppear {
                scanner.onFrame = { frame in
                    model.see(frame.recognition, imageSize: frame.imageSize, full: frame.isFull)
                }
                scanner.start()
            }
            .onDisappear { scanner.stop() }
        } else {
            ContentUnavailableView("No camera", systemImage: "camera.fill",
                                   description: Text("Use Photo or Type in the simulator."))
        }
    }
}

/// A photo with the network drawn over it.
private struct PhotoInput: View {
    let model: SceneModel
    let layers: NetworkLayers
    var onSelect: (GraphLayout.Key) -> Void
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var reading = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let image {
                // centred, aspect-fit: OverlayView maps the word boxes the same way
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("pickedPhoto")
                if let response = model.response {
                    OverlayView(response: response.showing(layers), model: model, fill: false,
                                onSelect: onSelect)
                }
            }
            PhotosPicker(selection: $item, matching: .images) {
                Label(image == nil ? "Choose a photo" : "Another photo", systemImage: "photo")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxHeight: .infinity, alignment: image == nil ? .center : .bottom)
            .padding(12)
            if reading { ProgressView().tint(.white).frame(maxHeight: .infinity) }
        }
        .clipped()
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self),
                      let ui = UIImage(data: data) else { return }
                await read(ui)
            }
        }
        .task {
            // `-photo <path>` launch argument: read an image file as if it had been picked
            if image == nil, let path = LaunchOptions.photoPath, let ui = UIImage(contentsOfFile: path) {
                await read(ui)
            }
        }
    }

    private func read(_ ui: UIImage) async {
        guard let cg = ui.cgImage else { return }
        reading = true
        defer { reading = false }
        image = ui
        let orientation = ui.cgOrientation
        let recognition = await Task.detached {
            (try? WordExtractor.recognize(in: cg, orientation: orientation)) ?? Recognition()
        }.value
        model.reset()
        model.see(recognition, imageSize: ui.size, full: true, still: true)
    }
}

/// Launch arguments for demos and UI tests: `-source photo|type|camera`, `-photo <path>`,
/// `-demo` (connect the sample typed text).
enum LaunchOptions {
    static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static var source: ContentView.Source? {
        value(after: "-source").flatMap { ContentView.Source(rawValue: $0.capitalized) }
    }
    static var photoPath: String? { value(after: "-photo") }
}

private struct TypeInput: View {
    let model: SceneModel
    @State private var text = "Farmacia aperta tutta la notte, padre\npaternalistic nocturnal pharmacy open night"

    var body: some View {
        VStack {
            TextEditor(text: $text)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            Button("Connect", systemImage: "point.3.connected.trianglepath.dotted") {
                model.set(typed: text)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .onAppear {
            // `-demo` launch argument: connect the sample words straight away (screenshots, UI checks)
            if ProcessInfo.processInfo.arguments.contains("-demo") { model.set(typed: text) }
        }
    }
}

extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
