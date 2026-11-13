import PhotosUI
import SwiftUI

/// Scavenger: an ancestor to hunt for in the world. Photograph a sign, a label, a page:
/// every word read from it is checked, and any that descends from the ancestor is a find.
/// One point per ancestor found; skip to another any time.
struct ScavengerView: View {
    @State private var target: GameRoot?
    @State private var error: String?
    @State private var score = 0
    @State private var finds: [(GameCheck.Found, GameCheck)] = []
    @State private var status: String?
    @State private var busy = false
    @State private var item: PhotosPickerItem?
    @State private var showCamera = false
    @State private var typed = ""
    private let api = APIClient.fromSettings()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                ScorePill(label: "Found", value: "\(score)", color: Game.scavenger.color)
            }
            .padding(.horizontal)
            if let target {
                ScrollView { board(target).padding() }
            } else {
                GameLoading(error: error) { Task { await load() } }
            }
        }
        .task { if target == nil { await load() } }
        .onChange(of: item) {
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) {
                    await read(ui)
                }
                self.item = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { image in
                showCamera = false
                if let image { Task { await read(image) } }
            }
            .ignoresSafeArea()
        }
    }

    private func board(_ t: GameRoot) -> some View {
        VStack(spacing: 18) {
            Text("Find, around you, a word that comes from").foregroundStyle(.secondary)
            RootTitle(node: t.root)
            Text("Signs, menus, labels, books — in any language.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: {
                        Label("Photograph", systemImage: "camera").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Game.scavenger.color).foregroundStyle(IconPalette.navy)
                }
                PhotosPicker(selection: $item, matching: .images) {
                    Label("From photos", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(busy)

            // the simulator has no camera; and a word in sight may be quicker typed
            HStack {
                TextField("…or type a word you see", text: $typed)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await check([typed]); typed = "" } }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("scavengerWord")
            }

            if busy { ProgressView("Reading…") }
            if let status {
                Text(status).multilineTextAlignment(.center)
                    .foregroundStyle(finds.isEmpty ? IconPalette.coral : IconPalette.mint)
                    .accessibilityIdentifier("scavengerStatus")
            }
            ForEach(Array(finds.enumerated()), id: \.offset) { _, find in
                VStack(alignment: .leading, spacing: 4) {
                    Text(find.0.text).font(.system(.title3, design: .serif))
                    PathLine(path: find.0.path, node: find.1.node)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Game.scavenger.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            Button(finds.isEmpty ? "Skip — another ancestor" : "Next ancestor") {
                Task { await load() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("scavengerNext")
            if finds.isEmpty, !t.examples.isEmpty {
                Text("Hint: \(t.examples.prefix(3).joined(separator: ", "))…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func read(_ ui: UIImage) async {
        guard let cg = ui.cgImage else { return }
        busy = true
        let orientation = ui.cgOrientation
        let recognition = await Task.detached {
            (try? WordExtractor.recognize(in: cg, orientation: orientation)) ?? Recognition()
        }.value
        busy = false
        let words = recognition.words.map(\.text)
        if words.isEmpty {
            status = "No words read in that picture."
            return
        }
        await check(words)
    }

    private func check(_ words: [String]) async {
        let words = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let target, !words.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            // signs are in any language: let the backend tell
            let result = try await api.check(root: target.root.id, words: words, lang: nil)
            if let hit = result.found.first {
                let first = finds.isEmpty
                withAnimation { finds += result.found.map { ($0, result) } }
                if first { score += 1 }
                status = "Found! “\(hit.text)” comes from \(target.root.word)."
            } else {
                status = words.count == 1
                    ? "“\(words[0])” doesn't come from \(target.root.word). Keep looking."
                    : "None of the \(words.count) words read comes from \(target.root.word). Keep looking."
            }
        } catch {
            status = "Can't reach the server."
        }
    }

    private func load() async {
        error = nil
        target = nil
        finds = []
        status = nil
        do {
            // the game's language only shapes the ancestor; finds can be in any language
            target = try await api.gameRoot(lang: GameLanguage.current)
        } catch {
            self.error = "Couldn't find an ancestor: \(error.localizedDescription)"
        }
    }
}

/// The system camera, for one photo.
struct CameraCapture: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
