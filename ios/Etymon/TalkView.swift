import SwiftUI

/// Talk: the space a conversation grows. Tap the microphone and talk; each speaker's words
/// appear in their colour with their trees of ancestors, and connections form (with a
/// chime) as the words meet. Drag to turn, pinch to zoom, tap a word to explore it.
///
/// Laid out by how often things are used: what you look at on top (Explore or Connect,
/// view options, the scene's menu), the tree in the middle with subtitles over its foot,
/// and the microphone at the bottom, within reach of the thumb, showing what it hears.
/// A tap on empty space hides the bars; another brings them back.
struct TalkView: View {
    let session: TalkSession
    var saving = false
    var onSave: () -> Void = {}
    var onStartOver: () -> Void = {}

    /// Speakers picked out (by number): only their words are drawn. Empty: everyone.
    @State private var chosen: Set<Int> = []
    @AppStorage("talkView") private var view: Vision = .explore
    @AppStorage(ExploreScope.storageKey) private var scope: ExploreScope = .whole
    @AppStorage(TreeDepth.storageKey) private var treeDepth = TreeDepth.defaultValue
    @State private var selection: ContentView.Selection?
    @State private var showOptions = false
    @State private var confirmStartOver = false
    /// The bars hidden: only the tree (and a small listening badge).
    @State private var immersive = false
    /// A word is open in Explore's panel: the subtitles move to the top, out of its way.
    @State private var wordOpen = false

    /// Two ways to see the conversation: the space its trees grow in, or (as in Type) the
    /// network of its connections, word to word.
    enum Vision: String, CaseIterable, Identifiable {
        case explore = "Explore", connect = "Connect"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !immersive {
                topBar
                filterSummary
            }
            ZStack(alignment: wordOpen ? .top : .bottom) {
                content
                popups
                    .padding(12)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if immersive { immersiveBadge }
            }
            .clipped()
            if !immersive {
                TalkDock(session: session)
            }
        }
        .animation(.snappy, value: immersive)
        .animation(.snappy, value: wordOpen)
        .onAppear { session.connectShown = view == .connect }
        .onChange(of: view) { _, v in
            session.connectShown = v == .connect
            wordOpen = false
        }
        .onChange(of: chosen) { _, c in session.connectSpeakers = c }
        .sheet(isPresented: $showOptions) {
            TalkOptions(session: session, chosen: $chosen)
        }
        .sheet(item: $selection) { selection in
            NavigationStack {
                switch selection {
                case .connection(let c):
                    if let response = session.connectScene {
                        ConnectionDetail(connection: c, response: response)
                            .navigationTitle("Connection")
                    }
                case .word(let text, let lang):
                    WordDetail(text: text, lang: lang)
                case .graph:
                    EmptyView()
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Start a new conversation?", isPresented: $confirmStartOver,
                            titleVisibility: .visible) {
            Button("Save to library…", action: onSave)
            Button("Discard and start over", role: .destructive, action: onStartOver)
        } message: {
            Text("The words and network so far go away. Save them to your library "
                 + "to keep them — saved scenes work offline.")
        }
        .background(Color(red: 0.05, green: 0.06, blue: 0.1))
        .environment(\.colorScheme, .dark)
        .onDisappear { session.stop() }
        .onChange(of: session.speakers.isEmpty) { _, empty in if empty { chosen = [] } }
        .task {
            // `-talkdemo` launch argument: a scripted conversation through the real backend,
            // for screenshots and the simulator (which has no one to listen to)
            guard ProcessInfo.processInfo.arguments.contains("-talkdemo"), session.isEmpty else { return }
            for (voice, lang, text) in Self.demo {
                await session.heard(text: text, lang: lang, voice: voice)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    static let demo: [(String, String, String)] = [
        ("P1", "it", "Mio padre lavora di notte in farmacia"),
        ("P2", "en", "My father works at night too"),
        ("P1", "it", "La notte è lunga, il lavoro è duro"),
        ("P2", "en", "A long night of hard work, the pharmacy is open"),
        ("P3", "de", "Mein Vater arbeitet in der Nacht"),
    ]

    // MARK: top

    /// What you see (Explore or Connect), how (view options), and the conversation's menu.
    private var topBar: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $view) {
                ForEach(Vision.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .accessibilityIdentifier("talkVision")
            Spacer(minLength: 0)
            if APIClient.isLocal { languageMenu }
            Button {
                showOptions = true
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("View options")
            .accessibilityIdentifier("talkOptions")
            Menu {
                Button("Save to library…", systemImage: "bookmark", action: onSave)
                    .disabled(session.isEmpty || saving)
                Button("Start over…", systemImage: "trash", role: .destructive) {
                    confirmStartOver = true
                }
                .disabled(session.isEmpty)
            } label: {
                Group {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Conversation")
            .accessibilityIdentifier("talkMenu")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(red: 0.09, green: 0.1, blue: 0.15))
    }

    /// The languages Talk listens for, when it listens on the phone (no server): up to
    /// three, told apart utterance by utterance.
    private var languageMenu: some View {
        Menu {
            Section {
                Toggle("Auto: find other languages", systemImage: "sparkles", isOn: Binding(
                    get: { session.autoLanguages },
                    set: { on in Task { await session.setAutoLanguages(on) } }))
            } footer: {
                Text("When someone speaks a language not listed below, Talk works out which, and listens for it too.")
            }
            Section("Listen for (up to \(OnDeviceSpeech.maxLanguages))") {
                ForEach(session.listenLanguages, id: \.self) { code in
                    Toggle(TalkCaption.name(code), isOn: Binding(
                        get: { session.listenFor.contains(code) },
                        set: { _ in Task { await session.toggleListening(for: code) } }))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(session.listenFor.isEmpty ? "–" : session.listenFor.map { $0.uppercased() }.joined(separator: "·"))
                if session.autoLanguages { Image(systemName: "sparkles").font(.caption2) }
            }
            .font(.callout.bold().monospaced())
            .frame(minWidth: 24, minHeight: 24)
        }
        .menuActionDismissBehavior(.disabled)
        .buttonStyle(.bordered)
        .accessibilityLabel("Listening for \(session.listenFor.map(TalkCaption.name).joined(separator: ", "))")
        .accessibilityIdentifier("talkLanguage")
        .task { await session.loadListenLanguages() }
    }

    /// Only when something is filtered: what, in one line. Tap to change, ✕ to see all.
    @ViewBuilder private var filterSummary: some View {
        let parts = filterParts
        if !parts.isEmpty {
            HStack(spacing: 8) {
                Button {
                    showOptions = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        Text(parts.joined(separator: " · ")).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("talkFilters")
                Button {
                    chosen = []
                    scope = .whole
                    treeDepth = TreeDepth.all
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Show everything")
                .accessibilityIdentifier("clearTalkFilters")
            }
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.28))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var filterParts: [String] {
        var parts: [String] = []
        if !chosen.isEmpty {
            let numbers = chosen.sorted().map(String.init).joined(separator: ", ")
            parts.append(chosen.count == 1 ? "Speaker \(numbers)" : "Speakers \(numbers)")
        }
        switch scope {
        case .whole: break
        case .roots: parts.append("Shared roots")
        case .meanings: parts.append("Same meaning")
        case .both: parts.append("Connections only")
        }
        if treeDepth != TreeDepth.all {
            parts.append(treeDepth == 0 ? "No steps between" : "\(treeDepth) step\(treeDepth == 1 ? "" : "s") between")
        }
        return parts
    }

    // MARK: middle

    @ViewBuilder private var content: some View {
        switch view {
        case .explore:
            if session.isEmpty {
                empty
            } else {
                ExploreView(graph: session.graph, title: "Talk", follow: true,
                            emptyHint: "Tap a word to explore it — or one of the words said:",
                            speakers: chosen, showsHeader: false,
                            panelOnlyWhenSelected: true,
                            onTapEmpty: { immersive.toggle() },
                            onSelect: { wordOpen = $0 != nil })
                    .id(ObjectIdentifier(session.graph))  // Clear starts a new space
            }
        case .connect:
            connect
        }
    }

    /// Connect: the words said, joined where they share a root or mean the same.
    @ViewBuilder private var connect: some View {
        let layers: NetworkLayers = scope == .roots ? .roots : scope == .meanings ? .meanings : .both
        if let scene = session.connectScene, !scene.words.isEmpty {
            NetworkView(response: scene.showing(layers), middle: treeDepth) { key in
                selection = ContentView.Selection.of(key, in: scene)
            }
            .overlay(alignment: .topTrailing) {
                if session.connectLoading { ProgressView().padding(8) }
            }
            .accessibilityIdentifier("talkConnect")
        } else if session.connectLoading {
            ProgressView("Connecting the words said…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 54)).foregroundStyle(.secondary)
            Text(session.listening ? "Listening — start talking." : "Tap the microphone below and talk.")
                .font(.title3.bold())
            Text("Every word said grows its tree of ancestors here, in its speaker's colour. "
                 + "When words meet in a shared root, or mean the same, they connect.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if !session.languages.isEmpty {
                Text("Understands " + session.languages.map(TalkCaption.name).sorted()
                    .joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bars hidden: still plain whether it's listening. Tap to bring the bars back.
    private var immersiveBadge: some View {
        Button {
            immersive = false
        } label: {
            HStack(spacing: 6) {
                if session.listening {
                    LevelMeter(level: session.level, color: session.talking ? .green : .red)
                } else {
                    Image(systemName: "mic.slash")
                }
                Image(systemName: "chevron.down")
            }
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(10)
        .accessibilityLabel("Show controls")
        .accessibilityIdentifier("talkShowBars")
    }

    /// What comes and goes, like subtitles: the latest utterance, the latest connection.
    private var popups: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).padding(8)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            }
            if let caption = session.caption {
                TalkCaption(caption: caption)
                    .transition(.opacity)
                    .accessibilityIdentifier("caption")
            } else if let notice = session.notice {
                Label(notice, systemImage: "waveform.slash")
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
                    .accessibilityIdentifier("talkNotice")
            }
            if let link = session.lastConnection {
                Label(link, systemImage: "link")
                    .font(.caption.bold()).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(.black)
                    .background(Color(red: 1.0, green: 0.82, blue: 0.3), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .id(link)
                    .accessibilityIdentifier("lastConnection")
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: session.lastConnection)
        .animation(.easeOut(duration: 0.6), value: session.caption?.id)
        .animation(.easeOut(duration: 0.4), value: session.notice)
    }
}

/// View options for Talk, in words: what to show, how many steps between words and roots,
/// whose words, and whether connections chime.
struct TalkOptions: View {
    let session: TalkSession
    @Binding var chosen: Set<Int>
    @AppStorage(ExploreScope.storageKey) private var scope: ExploreScope = .whole
    @AppStorage(TreeDepth.storageKey) private var treeDepth = TreeDepth.defaultValue
    @AppStorage(Chimes.storageKey) private var sound = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Show") {
                    Picker("Show", selection: $scope) {
                        ForEach(ExploreScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    .accessibilityIdentifier("optionScope")
                }
                Section {
                    Picker("Steps between", selection: $treeDepth) {
                        ForEach(TreeDepth.choices + [TreeDepth.all], id: \.self) {
                            Text(TreeDepth.title($0)).tag($0)
                        }
                    }
                    .accessibilityIdentifier("optionSteps")
                } header: {
                    Text("Steps between words and roots")
                } footer: {
                    Text("Words and the roots they share are always shown. Steps left out "
                         + "become a dotted shortcut that says how many.")
                }
                Section {
                    if session.speakers.isEmpty {
                        Text("No one has spoken yet.").foregroundStyle(.secondary)
                    } else {
                        Button {
                            chosen = []
                        } label: {
                            row(title: "Everyone", detail: nil, color: nil, on: chosen.isEmpty)
                        }
                        .accessibilityIdentifier("speakerEveryone")
                        ForEach(session.speakers) { s in
                            Button {
                                if chosen.contains(s.number) { chosen.remove(s.number) } else { chosen.insert(s.number) }
                            } label: {
                                row(title: s.title,
                                    detail: [s.lang.map(TalkCaption.name), "\(s.words) words"]
                                        .compactMap { $0 }.joined(separator: " · "),
                                    color: Color(NetworkScene.speakerColor(s.number)),
                                    on: chosen.contains(s.number))
                            }
                            .accessibilityIdentifier("speaker-\(s.number)")
                        }
                    }
                } header: {
                    Text("Speakers")
                } footer: {
                    Text("Pick one or more to see only their words and where they meet.")
                }
                Section {
                    Toggle("Chime when words connect", isOn: $sound)
                        .accessibilityIdentifier("sound")
                }
            }
            .navigationTitle("View options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(title: String, detail: String?, color: Color?, on: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color ?? .secondary.opacity(0.4)).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).bold() }
        }
        .contentShape(Rectangle())
    }
}
