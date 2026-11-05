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
