import SwiftData
import SwiftUI

/// A chain of steps read top to bottom: word, "inherited from", ancestor, ...
struct ChainView: View {
    let steps: [Step]
    let node: (Int) -> Node?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Text(describe(kind: step.kind))
                        .font(.caption).foregroundStyle(color(for: step.kind))
                        .padding(.leading, 12)
                }
                if let n = node(step.node) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(n.word).font(.body.weight(.semibold)).italic(n.reconstructed)
                        Text(n.language).font(.caption).foregroundStyle(.secondary)
                    }
                    if let gloss = n.gloss {
                        Text(gloss).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }
}

/// How two scene words are related through a shared ancestor.
struct ConnectionDetail: View {
    let connection: Connection
    let response: SceneResponse

    var body: some View {
        let a = response.words[connection.a].text, b = response.words[connection.b].text
        let meet = response.node(connection.meet)
        List {
            Section {
                Text("**\(a)** and **\(b)** both go back to *\(meet?.word ?? "?")* (\(meet?.language ?? "")).")
                if let depth = connection.depth {
                    LabeledContent("Search depth needed", value: depth.formatted())
                        .font(.caption)
                }
            }
            Section(a) { ChainView(steps: connection.pathA, node: response.node) }
            Section(b) { ChainView(steps: connection.pathB, node: response.node) }
            if !connection.deeper.isEmpty {
                Section("Deeper") {
                    ChainView(steps: [Step(node: connection.meet, kind: nil)] + connection.deeper,
                              node: response.node)
                }
            }
        }
    }
}

/// A single word's lineage, fetched on tap.
struct WordDetail: View {
    let text: String
    let lang: String?
    @State private var result: WordResponse?
    @State private var error: String?

    var body: some View {
        List {
            if let result {
                ForEach(result.entries, id: \.term) { entry in
                    Section {
                        ChainView(steps: [Step(node: entry.term, kind: nil)] + entry.lineage,
                                  node: result.node)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(text)
        .task {
            do { result = try await APIClient.fromSettings().word(text, lang: lang) }
            catch { self.error = "No etymology found for \(text)." }
        }
    }
}

struct SettingsView: View {
    @AppStorage(APIClient.baseURLKey) private var baseURL = APIClient.defaultBaseURL
    @AppStorage(SearchDepth.storageKey) private var depth = SearchDepth.defaultValue
    @AppStorage(TreeDepth.storageKey) private var treeDepth = TreeDepth.defaultValue
    @AppStorage(WordLimit.storageKey) private var maxWords = WordLimit.defaultValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Backend")
                } footer: {
                    Text("The simulator can use localhost. On a phone, use your Mac's address, "
                         + "e.g. http://192.168.1.20:8000, and start the server with --host 0.0.0.0.")
                }
                Section {
                    Stepper {
                        maxWords = WordLimit.next(after: maxWords)
                    } onDecrement: {
                        maxWords = WordLimit.previous(before: maxWords)
                    } label: {
                        LabeledContent("Maximum words", value: "\(maxWords)").monospacedDigit()
                    }
                    .accessibilityIdentifier("maxWords")
                    Button("Reset to \(WordLimit.defaultValue)") { maxWords = WordLimit.defaultValue }
                        .disabled(maxWords == WordLimit.defaultValue)
                } header: {
                    Text("Words")
                } footer: {
                    Text("How many words a scene can discover at once. Words still in view keep "
                         + "their place; new ones (largest first) take the place of words that have "
                         + "left the frame. More words find more connections, but the network gets "
                         + "busier and slower to update: above about 100, the network and Explore "
                         + "get crowded.")
                }
                SavedSettingsSection()
                Section {
                    Picker("Steps between", selection: $treeDepth) {
                        ForEach(TreeDepth.choices, id: \.self) { Text(TreeDepth.title($0)).tag($0) }
                        Text(TreeDepth.title(TreeDepth.all)).tag(TreeDepth.all)
                    }
                    .accessibilityIdentifier("treeDepthSetting")
                } header: {
                    Text("Trees")
                } footer: {
                    Text("Words and their roots are always drawn; this sets how many of the steps "
                         + "between them are shown in Explore, Talk and AR. Fewer keeps the network "
                         + "readable: a line then jumps from the last step shown straight to the root, "
                         + "thin, with the number of steps it skips. Also in the menu over those views.")
                }
                Section {
                    SearchDepthStepper()
                    Button("Reset to \(SearchDepth.defaultValue.formatted())") {
                        depth = SearchDepth.defaultValue
                    }
                    .disabled(depth == SearchDepth.defaultValue)
                } header: {
                    Text("Search")
                } footer: {
                    Text("How far back each word's ancestry is searched for shared roots. Each link "
                         + "costs about 1 (a jump to a reconstructed root costs 6). Deeper finds older, "
                         + "more distant connections but can be noisier and slower.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// How many steps between words and roots to draw (Explore, Talk, AR): a menu.
struct TreeDepthMenu: View {
    @AppStorage(TreeDepth.storageKey) private var depth = TreeDepth.defaultValue

    var body: some View {
        Menu {
            Picker("Steps between words and roots", selection: $depth) {
                ForEach(TreeDepth.choices, id: \.self) { Text(TreeDepth.title($0)).tag($0) }
                Text(TreeDepth.title(TreeDepth.all)).tag(TreeDepth.all)
            }
        } label: {
            Label(TreeDepth.short(depth), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .monospacedDigit()
        }
        .accessibilityLabel("Steps between words and roots: \(TreeDepth.title(depth))")
        .accessibilityIdentifier("treeDepth")
    }
}

/// Whole network or only the connecting paths (Explore, Talk): a menu.
struct ExploreScopeMenu: View {
    @AppStorage(ExploreScope.storageKey) private var scope: ExploreScope = .whole

    var body: some View {
        Menu {
            Picker("Show", selection: $scope) {
                ForEach(ExploreScope.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label(scope.short, systemImage: scope == .whole ? "circle.hexagongrid" : "link")
        }
        .accessibilityLabel("Show: \(scope.title)")
        .accessibilityIdentifier("exploreScope")
    }
}

/// Search depth control, shared by Settings and the network header. Stored in
/// UserDefaults; ContentView asks the backend again when it changes.
struct SearchDepthStepper: View {
    var compact = false
    @AppStorage(SearchDepth.storageKey) private var depth = SearchDepth.defaultValue

    var body: some View {
        Stepper(value: $depth, in: SearchDepth.range, step: 1) {
            if compact {
                Text("Depth \(depth.formatted())").monospacedDigit()
            } else {
                LabeledContent("Search depth", value: depth.formatted()).monospacedDigit()
            }
        }
        .accessibilityIdentifier("searchDepth")
    }
}

/// Settings for the saved network: location, and what is kept for offline use.
private struct SavedSettingsSection: View {
    @AppStorage(SaveSettings.locationKey) private var rememberPlace = true
    @Query private var scenes: [SavedScene]
    @Environment(\.modelContext) private var context
    @State private var usage = OfflineCache.shared.usage()
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Toggle("Remember where scenes are saved", isOn: $rememberPlace)
            LabeledContent("Saved scenes", value: "\(scenes.count)")
            LabeledContent("Offline lookups",
                           value: "\(usage.count) · \(usage.bytes.formatted(.byteCount(style: .file)))")
            Button("Clear offline lookups") {
                OfflineCache.shared.clear()
                usage = OfflineCache.shared.usage()
            }
            .disabled(usage.count == 0)
            Button("Delete all saved scenes", role: .destructive) { confirmDelete = true }
                .disabled(scenes.isEmpty)
                .confirmationDialog("Delete all \(scenes.count) saved scenes?",
                                    isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete all", role: .destructive) {
                        scenes.forEach(context.delete)
                        try? context.save()
                    }
                }
        } header: {
            Text("My network")
        } footer: {
            Text("Saved scenes stay on this phone. Lookups (each word's lineage, Expand in "
                 + "Explore) are kept too, so saved scenes can be explored without the server.")
        }
    }
}
