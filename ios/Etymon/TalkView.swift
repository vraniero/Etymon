import SwiftUI

/// Talk: the space a conversation grows. Tap the microphone and talk; each speaker's words
/// appear in their colour with their trees of ancestors, and connections form (with a
/// chime) as the words meet. Drag to turn, pinch to zoom, tap a word to explore it.
struct TalkView: View {
    let session: TalkSession
    var saving = false
    var onSave: () -> Void = {}
    @AppStorage(Chimes.storageKey) private var sound = true
    /// Speakers picked out (by number): only their words are drawn. Empty: everyone.
    @State private var chosen: Set<Int> = []
    @AppStorage("talkView") private var view: Vision = .explore
    @AppStorage(ExploreScope.storageKey) private var scope: ExploreScope = .whole
    @AppStorage(TreeDepth.storageKey) private var treeDepth = TreeDepth.defaultValue
    @State private var selection: ContentView.Selection?
    /// Folded: only the microphone and a one-line status stay, the rest is tree.
    @AppStorage("talkControlsFolded") private var folded = false

    /// Two ways to see the conversation: the space its trees grow in, or (as in Type) the
    /// network of its connections, word to word.
    enum Vision: String, CaseIterable, Identifiable {
        case explore = "Explore", connect = "Connect"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            switch view {
            case .explore:
                ZStack(alignment: .top) {
                    if session.isEmpty {
                        empty
                    } else {
                        ExploreView(graph: session.graph, title: "Talk", follow: true,
                                    emptyHint: "Tap a word to explore it — or one of the words said:",
                                    speakers: chosen, showsHeader: false)
                            .id(ObjectIdentifier(session.graph))  // Clear starts a new space
                    }
                    controls
                }
            case .connect:
                VStack(spacing: 0) {
                    controls
                    connect
                }
            }
        }
        .onAppear { session.connectShown = view == .connect }
        .onChange(of: view) { _, v in session.connectShown = v == .connect }
        .onChange(of: chosen) { _, c in session.connectSpeakers = c }
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
            ProgressView("Connecting the words said…").frame(maxHeight: .infinity)
        } else {
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 54)).foregroundStyle(.secondary)
            Text(session.listening ? "Listening — start talking." : "Tap the microphone and talk.")
                .font(.title3.bold())
            if !session.languages.isEmpty {
                Text("Understands " + session.languages.map(TalkCaption.name).sorted()
                    .joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Text("Every word said grows its tree of ancestors here, in its speaker's colour. "
                 + "When words meet in a shared root, or mean the same, they connect.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One chip per speaker, scrolling sideways when there are many. Tap to show only that
    /// speaker's words; tap more to add them; tap again to let go. "All" clears the choice.
    private var speakerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !chosen.isEmpty {
                    Button {
                        chosen = []
                    } label: {
                        Label("All", systemImage: "person.3.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .accessibilityIdentifier("allSpeakers")
                }
                ForEach(session.speakers) { s in
                    let picked = chosen.contains(s.number)
                    let dimmed = !chosen.isEmpty && !picked
                    Button {
                        if picked { chosen.remove(s.number) } else { chosen.insert(s.number) }
                    } label: {
                        HStack(spacing: 4) {
                            if picked { Image(systemName: "checkmark") }
                            Text(s.title + (s.lang.map { " · \($0)" } ?? "") + " · \(s.words)")
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(.black)
                        .background(Color(NetworkScene.speakerColor(s.number)).opacity(dimmed ? 0.35 : 1),
                                    in: Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: picked ? 2 : 0))
                    }
                    .accessibilityLabel(s.title + (picked ? ", shown" : ""))
                    .accessibilityIdentifier("speaker-\(s.number)")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .animation(.snappy, value: chosen)
    }

    private var micButton: some View {
        Button {
            if session.listening { session.stop() } else { Task { await session.start() } }
        } label: {
            Image(systemName: session.listening ? "mic.fill" : "mic.slash.fill")
                .font(.title3)
                .symbolEffect(.variableColor, isActive: session.talking)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderedProminent)
        .tint(session.listening ? .red : .gray)
        .accessibilityLabel(session.listening ? "Stop listening" : "Listen")
        .accessibilityIdentifier("listen")
    }

    private var foldButton: some View {
        Button {
            withAnimation(.snappy) { folded.toggle() }
        } label: {
            Image(systemName: folded ? "chevron.down" : "chevron.up")
                .font(.callout.bold())
                .frame(width: 22, height: 30)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(folded ? "Show controls" : "Hide controls")
        .accessibilityIdentifier("foldTalkControls")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if folded {
                HStack(spacing: 8) {
                    micButton
                    TalkStatus(session: session, compact: true)
                    Spacer(minLength: 0)
                    foldButton
                }
            } else {
                unfolded
            }
            popups
        }
        .foregroundStyle(.white)
        .animation(.snappy, value: session.lastConnection)
        .animation(.easeOut(duration: 0.6), value: session.caption?.id)
        .animation(.easeOut(duration: 0.4), value: session.notice)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var unfolded: some View {
        HStack(spacing: 8) {
            micButton
            Button {
                sound.toggle()
            } label: {
                Image(systemName: sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(width: 22, height: 30)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(sound ? "Sound on" : "Sound off")
            .accessibilityIdentifier("sound")
            Group {
                ExploreScopeMenu()
                TreeDepthMenu()
            }
            .font(.callout.bold())
            .buttonStyle(.bordered)
            .frame(height: 30)
            Button(action: onSave) {
                if saving {
                    ProgressView().controlSize(.small).frame(width: 22, height: 30)
                } else {
                    Image(systemName: "bookmark").frame(width: 22, height: 30)
                }
            }
            .buttonStyle(.bordered)
            .disabled(session.isEmpty || saving)
            .accessibilityLabel("Save to library")
            .accessibilityIdentifier("saveTalk")
            Spacer(minLength: 0)
            foldButton
        }
        TalkStatus(session: session)
            .frame(maxWidth: 420)
        HStack {
            Picker("View", selection: $view) {
                ForEach(Vision.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("talkVision")
            Spacer()
            if !session.isEmpty {
                Text("\(session.graph.nodes.count) words · \(session.graph.edges.count) links")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !session.speakers.isEmpty {
            speakerStrip
        }
    }

    /// What comes and goes: the latest utterance, the latest connection, an error.
    @ViewBuilder private var popups: some View {
        if let caption = session.caption {
            TalkCaption(caption: caption)
                .transition(.opacity)
                .accessibilityIdentifier("caption")
        } else if let notice = session.notice {
            Label(notice, systemImage: "waveform.slash")
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
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
        if let error = session.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption).padding(8)
                .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
