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
        var id: String {
            switch self {
            case .connection(let c): return "c\(c.id)"
            case .word(let t, let l): return "w\(t)\(l ?? "")"
            }
        }
    }

    @State private var model = SceneModel()
    @State private var source: Source = CameraScanner.isAvailable ? .camera : .type
    @State private var selection: Selection?
    @State private var showSettings = false
    @State private var fullPaths = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 8)

                input
                    .frame(maxWidth: .infinity)
                    .frame(height: source == .type ? 130 : 240)
                    .clipped()

                status
                network
            }
            .navigationTitle("Etymon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", systemImage: "trash") { model.reset() }
                        .disabled(model.words.isEmpty)
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
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    @ViewBuilder private var input: some View {
        switch source {
        case .camera: CameraInput(model: model)
        case .photo: PhotoInput(model: model)
        case .type: TypeInput(model: model)
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            if model.isLoading { ProgressView().controlSize(.small) }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if model.words.isEmpty {
                Text("Point at some text, pick a photo, or type a few words.")
            } else {
                let count = model.response?.connections.count ?? 0
                Text("\(model.words.count) words · \(count) connection\(count == 1 ? "" : "s")"
                     + (model.language.map { " · \($0)" } ?? ""))
            }
            Spacer()
            if model.response?.connections.isEmpty == false {
                Toggle("Full paths", isOn: $fullPaths)
                    .toggleStyle(.button).controlSize(.mini)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal).padding(.vertical, 6)
    }

    @ViewBuilder private var network: some View {
        if let response = model.response, !response.words.isEmpty {
            NetworkView(response: response, compact: !fullPaths) { key in
                select(key, in: response)
            }
        } else {
            Spacer()
        }
    }

    private func select(_ key: GraphLayout.Key, in response: SceneResponse) {
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

private struct CameraInput: View {
    let model: SceneModel
    @State private var scanner = CameraScanner()
    @State private var paused = false

    var body: some View {
        if CameraScanner.isAvailable {
            CameraPreview(session: scanner.session)
                .overlay(alignment: .bottomTrailing) {
                    Button(paused ? "Resume" : "Hold", systemImage: paused ? "play.fill" : "pause.fill") {
                        paused.toggle()
                        scanner.isPaused = paused
                    }
                    .buttonStyle(.borderedProminent).padding(10)
                }
                .onAppear {
                    scanner.onText = { model.add(text: $0) }
                    scanner.start()
                }
                .onDisappear { scanner.stop() }
        } else {
            ContentUnavailableView("No camera", systemImage: "camera.fill",
                                   description: Text("Use Photo or Type in the simulator."))
        }
    }
}

private struct PhotoInput: View {
    let model: SceneModel
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var reading = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
            PhotosPicker(selection: $item, matching: .images) {
                Label(image == nil ? "Choose a photo" : "Another photo", systemImage: "photo")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxHeight: .infinity, alignment: image == nil ? .center : .bottom)
            .padding(10)
            if reading { ProgressView() }
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                reading = true
                defer { reading = false }
                guard let data = try? await newItem.loadTransferable(type: Data.self),
                      let ui = UIImage(data: data), let cg = ui.cgImage else { return }
                image = ui
                let text = await Task.detached {
                    (try? WordExtractor.recognizeText(in: cg, orientation: ui.cgOrientation)) ?? ""
                }.value
                model.reset()
                model.add(text: text)
            }
        }
    }
}

private struct TypeInput: View {
    let model: SceneModel
    @State private var text = "Farmacia aperta tutta la notte, padre\npaternalistic nocturnal pharmacy"

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
