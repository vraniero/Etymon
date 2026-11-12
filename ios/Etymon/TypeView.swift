import SwiftUI

/// What the Type screen shows under the words: plain-language cards, or the diagram
/// (tree or map, NetworkStyle). Remembered.
enum TypeDisplay: String, CaseIterable, Identifiable {
    case story, tree, map
    static let storageKey = "typeView"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .story: return "Story"
        case .tree: return "Tree"
        case .map: return "Map"
        }
    }
}

/// Type: words in, connections out. The input shrinks to a row of word chips once
/// connected, so the results get the screen; they lead with plain sentences ("padre and
/// paternalistic both come from Latin pater"), with the tree and map one tap away. The
/// view options (which links, every step, search depth) sit together behind one button.
struct TypeScreen: View {
    let model: SceneModel
    @Binding var layers: NetworkLayers
    @Binding var fullPaths: Bool
    var onSelect: (GraphLayout.Key) -> Void
    var onSave: () -> Void
    var onExplore: () -> Void

    @State private var text = LaunchOptions.isDemo ? TypeExamples.demo : ""
    @State private var expanded = true  // the editor, rather than the chips row
    @State private var showOptions = false
    @FocusState private var focused: Bool
    @AppStorage("typeShowsStory") private var showsStory = true
    @AppStorage(NetworkStyle.storageKey) private var style: NetworkStyle = .tree

    var body: some View {
        VStack(spacing: 0) {
            if expanded || model.words.isEmpty { editor } else { wordsRow }
            if !model.words.isEmpty {
                summaryRow
                displayPicker
                results
            } else {
                emptyState
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", systemImage: "keyboard.chevron.compact.down") { focused = false }
                    .accessibilityIdentifier("hideKeyboard")
            }
        }
        .onChange(of: model.words.isEmpty) { _, isEmpty in
            if isEmpty { text = ""; expanded = true }  // started over
        }
        .onAppear {
            // `-demo` launch argument: connect the sample words straight away (screenshots, UI checks)
            if LaunchOptions.isDemo { connect() }
        }
    }

    // MARK: input

    private var editor: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.title3)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                if text.isEmpty {
                    Text("Type or paste some words — English, Italian, Spanish, French or German")
                        .font(.title3).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .frame(height: 120)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                if !model.words.isEmpty {
                    Button("Cancel") { focused = false; expanded = false }
                }
                Spacer()
                Button("Connect", systemImage: "point.3.connected.trianglepath.dotted", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(WordExtractor.words(in: text).isEmpty)
            }
        }
        .padding(.horizontal).padding(.bottom, 8)
    }

    /// Once connected: the words as chips, and Edit to change them.
    private var wordsRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(chipWords.enumerated()), id: \.offset) { _, word in
                        HStack(spacing: 3) {
                            Text(word.text)
                            if let lang = word.lang {
                                Text(lang).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
            Button("Edit", systemImage: "pencil") {
                expanded = true
                Task { @MainActor in focused = true }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityIdentifier("editWords")
        }
        .padding(.horizontal).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("typedWords")
    }

    private var chipWords: [(text: String, lang: String?)] {
        if let words = model.response?.words, !words.isEmpty {
            return words.map { ($0.text, $0.lang) }
        }
        return model.words.map { ($0, nil) }
    }

    private func connect() {
        focused = false
        model.set(typed: text)
        if !model.words.isEmpty { expanded = false }
    }

    /// Nothing typed yet: what this is, and a few sets to try.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Words from different languages often share an ancestor. Type a few and "
                 + "see where they meet.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Try").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(TypeExamples.all, id: \.title) { example in
                    Button {
                        text = example.text
                        connect()
                    } label: {
                        Label(example.title, systemImage: example.symbol)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("example-\(example.title)")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.top, 8)
    }

    // MARK: results

    /// One line: what was found, and what can be done with it.
    private var summaryRow: some View {
        HStack(spacing: 8) {
            if model.isLoading { ProgressView().controlSize(.small) }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).lineLimit(2)
            } else if let response = model.response {
                Text(summary(response)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("View options", systemImage: "slider.horizontal.3") { showOptions = true }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("viewOptions")
                .popover(isPresented: $showOptions) {
                    options.presentationCompactAdaptation(.popover)
                }
            Button("Save", systemImage: "bookmark", action: onSave)
                .labelStyle(.iconOnly)
                .disabled(model.response?.words.isEmpty ?? true)
                .accessibilityIdentifier("saveScene")
            Button("Explore", systemImage: "cube.transparent", action: onExplore)
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(model.response?.words.isEmpty ?? true)
                .accessibilityIdentifier("explore")
        }
        .font(.subheadline)
        .padding(.horizontal).padding(.bottom, 6)
    }

    private func summary(_ r: SceneResponse) -> String {
        let roots = r.connections.count, same = r.semanticLinks.count
        if roots == 0 && same == 0 { return "No connections yet" }
        return "\(roots) shared root\(roots == 1 ? "" : "s") · \(same) same meaning"
    }

    private var displayPicker: some View {
        Picker("Show as", selection: displayBinding) {
            ForEach(TypeDisplay.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal).padding(.bottom, 6)
        .accessibilityIdentifier("typeDisplay")
    }

    /// Story is the Type screen's own; Tree and Map are the shared NetworkStyle.
    private var displayBinding: Binding<TypeDisplay> {
        Binding(get: { showsStory ? .story : style == .map ? .map : .tree },
                set: { d in
                    showsStory = d == .story
                    if d != .story { style = d == .map ? .map : .tree }
                })
    }

    @ViewBuilder private var results: some View {
        if let response = model.response, !response.words.isEmpty {
            let shown = response.showing(layers)
            if showsStory {
                StoryList(response: shown, onSelect: onSelect)
            } else {
                NetworkView(response: shown, compact: !fullPaths, showsControls: false,
                            onSelect: onSelect)
            }
        } else {
            Spacer()
        }
    }

    /// Everything that changes how the results look, in one place.
    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Show").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Show", selection: $layers) {
                    ForEach(NetworkLayers.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("layersPicker")
            }
            Toggle(isOn: $fullPaths) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show every step")
                    Text("In the tree, every word between yours and the shared root")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!layers.showsRoots)
            .accessibilityIdentifier("fullPaths")
            Divider()
            if let search = model.response?.search {
                SearchDepthBar(search: search, stacked: true).padding(.horizontal, -16)
            } else {
                SearchDepthStepper()
            }
        }
        .padding()
        .frame(width: 330)
    }
}

/// Sample word sets for the empty Type screen.
enum TypeExamples {
    struct Example {
        let title: String
        let symbol: String
        let text: String
    }

    static let all = [
        Example(title: "A sign in Milan", symbol: "signpost.right",
                text: "Farmacia aperta tutta la notte\npharmacy open all night"),
        Example(title: "Family", symbol: "figure.2.and.child.holdinghands",
                text: "padre father Vater père paternal"),
        Example(title: "Night", symbol: "moon.stars",
                text: "notte nuit Nacht noche night nocturnal"),
        Example(title: "Heart", symbol: "heart",
                text: "cuore heart Herz cœur cardiac"),
    ]

    /// What `-demo` connects (screenshots, UI checks).
    static let demo = "Farmacia aperta tutta la notte, padre\npaternalistic nocturnal pharmacy open night"
}

// MARK: - Story

/// The connections as sentences, one card each: words that share a root (all the words
/// meeting at the same ancestor together), then words that mean the same without sharing
/// one, then the words nothing was found for. Tapping a root card opens its full story.
struct StoryList: View {
    let response: SceneResponse
    var onSelect: (GraphLayout.Key) -> Void

    struct RootGroup: Identifiable {
        let meet: Int
        var words: [Int]
        var distance: Double
        var id: Int { meet }
    }

    struct MeaningGroup: Identifiable {
        let meaning: String
        var words: [Int]
        var id: String { meaning }
    }

    var body: some View {
        let roots = Self.rootGroups(response)
        let meanings = Self.meaningGroups(response, besides: roots)
        let linked = Set(roots.flatMap(\.words) + meanings.flatMap(\.words))
        let unknown = response.words.indices.filter { response.words[$0].terms.isEmpty }
        let loose = response.words.indices.filter {
            !linked.contains($0) && !response.words[$0].terms.isEmpty
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if roots.isEmpty && meanings.isEmpty {
                    Text("No shared roots or meanings among these words yet. Add a few related "
                         + "words — the same word in other languages works well.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(roots) { rootCard($0) }
                ForEach(meanings) { meaningCard($0) }
                if !loose.isEmpty {
                    footnote("Nothing in common with the other words yet", loose)
                }
                if !unknown.isEmpty {
                    footnote("Not in the dictionary", unknown)
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
        }
    }

    // MARK: cards

    private func rootCard(_ group: RootGroup) -> some View {
        let meet = response.node(group.meet)
        // a word of the scene can itself be the ancestor (caffè for coffee)
        let isAncestor = group.words.filter { response.words[$0].terms.contains(group.meet) }
        let others = group.words.filter { !isAncestor.contains($0) }
        let subject = others.isEmpty ? group.words : others
        let together = subject.count == 1 ? "comes" : subject.count == 2 ? "both come" : "all come"
        let shared = sharedMeaning(of: group.words)
        return Button { onSelect(.term(group.meet)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label("Shared root", systemImage: "tree")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(Self.list(subject.map { word($0) })) \(together) from \(meet?.language ?? "") \(ancestor(meet))")
                    .font(.body)
                if let gloss = meet?.gloss, !gloss.isEmpty {
                    Text("“\(gloss)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if meet?.reconstructed == true {
                    Text("* reconstructed: never written down, worked out by comparing languages")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let shared {
                        Text("= \(shared)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.green))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(red: 1.0, green: 0.92, blue: 0.62).opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("storyCard")
    }

    private func meaningCard(_ group: MeaningGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Same meaning", systemImage: "equal.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(Self.list(group.words.map { word($0) })) \(group.words.count == 2 ? "both" : "all") mean “\(group.meaning)”, from different origins")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("meaningCard")
    }

    private func footnote(_ title: String, _ words: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(words, id: \.self) { i in
                    Button(response.words[i].text) { onSelect(.word(i)) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.top, 6)
    }

    private func word(_ i: Int) -> Text {
        Text(response.words[i].text).bold()
    }

    private func ancestor(_ node: Node?) -> Text {
        Text(node?.word ?? "?").bold().italic()
    }

    /// The meaning the words of a root group also share, if any (notte = night).
    private func sharedMeaning(of words: [Int]) -> String? {
        let set = Set(words)
        return response.semanticLinks.first { set.contains($0.a) && set.contains($0.b) }?.meaning
    }

    /// "a and b", "a, b and c".
    static func list(_ parts: [Text]) -> Text {
        guard var out = parts.first else { return Text("") }
        for (i, part) in parts.dropFirst().enumerated() {
            let separator = i == parts.count - 2 ? " and " : ", "
            out = Text("\(out)\(separator)\(part)")
        }
        return out
    }

    // MARK: grouping

    /// Connections grouped by where they meet: notte, nocturnal and night are one story.
    /// Biggest groups first, then the closest.
    static func rootGroups(_ r: SceneResponse) -> [RootGroup] {
        var groups: [Int: RootGroup] = [:]
        for c in r.connections {
            var g = groups[c.meet] ?? RootGroup(meet: c.meet, words: [], distance: c.distance)
            for w in [c.a, c.b] where !g.words.contains(w) { g.words.append(w) }
            g.distance = min(g.distance, c.distance)
            groups[c.meet] = g
        }
        return groups.values
            .map { var g = $0; g.words.sort(); return g }
            .sorted { ($0.words.count, -$0.distance) > ($1.words.count, -$1.distance) }
    }

    /// Same-meaning links grouped by meaning, leaving out those already told by a root
    /// card (their words share the root too).
    static func meaningGroups(_ r: SceneResponse, besides roots: [RootGroup]) -> [MeaningGroup] {
        var groups: [String: MeaningGroup] = [:]
        var order: [String] = []
        for link in r.semanticLinks {
            if groups[link.meaning] == nil { order.append(link.meaning) }
            var g = groups[link.meaning] ?? MeaningGroup(meaning: link.meaning, words: [])
            for w in [link.a, link.b] where !g.words.contains(w) { g.words.append(w) }
            groups[link.meaning] = g
        }
        let rootSets = roots.map { Set($0.words) }
        return order.compactMap { groups[$0] }
            .filter { g in !rootSets.contains { Set(g.words).isSubset(of: $0) } }
            .map { var g = $0; g.words.sort(); return g }
    }
}
