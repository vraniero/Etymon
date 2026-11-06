import ARKit
import SceneKit
import SwiftUI

/// AR: the words around you anchored where they are in the room, their shared roots
/// floating above them. Walk around and the network stays put; words read from different
/// walls and signs connect across the space.
///
/// With the microphone on, the people talking join in: each voice is a persona, found on
/// the face whose mouth moves as it speaks (or a screen or speaker in view, or somewhere
/// off camera), and the words it says float above it in its colour, linked to everything
/// else in the scene as they are said.
struct ARInput: View {
    let model: SceneModel
    let layers: NetworkLayers
    let exploring: Bool
    var onSelect: (GraphLayout.Key) -> Void
    var onExplore: () -> Void
    @State private var paused = false
    @State private var conversation = Conversation()
    /// One branch picked out by tapping a line; nil shows the whole network.
    @State private var focus: ARFocus?
    /// False until the camera's first frame: until then a placeholder, not a black screen.
    @State private var cameraReady = false

    static var isAvailable: Bool { ARWorldTrackingConfiguration.isSupported }

    var body: some View {
        if Self.isAvailable {
            ZStack(alignment: .bottomTrailing) {
                ARNetworkView(response: model.response?.showing(layers),
                              sceneIsEmpty: model.words.isEmpty, reading: !paused && !exploring,
                              running: !exploring, conversation: conversation,
                              personas: conversation.personas, focus: $focus, ready: $cameraReady,
                              onSelect: onSelect) { read in
                    model.see(read.recognition, imageSize: read.imageSize, full: true,
                              picture: read.picture)
                }
                .accessibilityIdentifier("arView")
                if !cameraReady { ARStarting().transition(.opacity) }
                ConversationOverlay(conversation: conversation)
                if focus != nil {
                    Button("Show all", systemImage: "point.3.filled.connected.trianglepath.dotted") {
                        focus = nil
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .padding(.top, 44)  // below the speakers' chips
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .accessibilityIdentifier("showAll")
                }
                HStack {
                    Button(conversation.listening ? "Stop listening" : "Listen",
                           systemImage: conversation.listening ? "mic.fill" : "mic.slash") {
                        if conversation.listening { conversation.stop() } else { Task { await conversation.start() } }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .tint(conversation.listening ? .red : .gray)
                    .accessibilityIdentifier("listen")
                    Button(paused ? "Collect" : "Hold", systemImage: paused ? "plus.viewfinder" : "pause.fill") {
                        paused.toggle()  // the network stays in place; no new words are read
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Explore", systemImage: "cube.transparent", action: onExplore)
                        .buttonStyle(.borderedProminent).tint(.indigo)
                        .disabled(model.response?.words.isEmpty ?? true)
                        .accessibilityIdentifier("explore")
                }
                .padding(12)
            }
            .clipped()
            .onAppear {
                conversation.onHeard = { [model] text, lang in model.hear(text, lang: lang) }
            }
            .onChange(of: model.words.isEmpty) { _, empty in
                if empty { conversation.clearWords(); focus = nil }
            }
            .onChange(of: exploring) { _, isExploring in if isExploring { conversation.stop() } }
            .onDisappear { conversation.stop() }
        } else {
            ContentUnavailableView("No AR", systemImage: "arkit",
                                   description: Text("AR needs an iPhone with world tracking."))
        }
    }
}

struct ARNetworkView: UIViewRepresentable {
    struct Read {
        let recognition: Recognition
        let imageSize: CGSize
        let picture: ScenePicture.Source?  // the frame read, for saving the scene
    }

    let response: SceneResponse?
    let sceneIsEmpty: Bool
    let reading: Bool
    let running: Bool
    let conversation: Conversation
    /// Passed so the view updates when someone speaks or moves to another place.
    let personas: [Conversation.Persona]
    @Binding var focus: ARFocus?
    @Binding var ready: Bool
    var onSelect: (GraphLayout.Key) -> Void
    var onRead: (Read) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.automaticallyUpdatesLighting = true
        view.antialiasingMode = .multisampling4X
        view.session.delegate = context.coordinator
        context.coordinator.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.tap(_:))))

        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(coaching)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        c.onRead = onRead
        c.listen(to: conversation)
        c.reading = reading
        c.focusBinding = $focus
        c.readyBinding = $ready
        c.setFocus(focus)
        c.setRunning(running)
        c.sceneIsEmpty(sceneIsEmpty)  // Clear: the anchors go too
        c.show(response)
    }

    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
        coordinator.setRunning(false)
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        weak var view: ARSCNView?
        var onSelect: (GraphLayout.Key) -> Void = { _ in }
        var onRead: (Read) -> Void = { _ in }
        var reading = true

        /// Where each word read so far is in the room, by lowercased word.
        private var anchors: [String: ARWordAnchor] = [:]
        private var response: SceneResponse?
        private var running = false

        /// Two kinds of read run side by side, as in Camera: a careful one about once a
        /// second (new words, language) and a quick one ~10 times a second that only moves
        /// the words already placed, so tags follow a book picked up or slid across the table.
        private var fullBusy = false, trackBusy = false
        private var lastFull = Date.distantPast, lastTrack = Date.distantPast
        private let fullInterval: TimeInterval = 1.0
        private let trackInterval: TimeInterval = 0.08
        /// False while the scene is in a script quick reads can't read (Cyrillic, Polish…):
        /// then tracking uses careful reads too, as often as they finish.
        private var trackFast = true
        /// Careful reads below the session's own work; tracking just above, it is what you see.
        private let fullQueue = DispatchQueue(label: "etymon.ar.read", qos: .utility)
        private let trackQueue = DispatchQueue(label: "etymon.ar.track", qos: .userInitiated)
        /// The camera at the previous frame, to tell when the phone is moving.
        private var lastCamera: (transform: simd_float4x4, time: TimeInterval)?
        private var drawn = ""  // signature of what is on screen

        /// The branch picked out by tapping a line, and the SwiftUI state it mirrors.
        private var focus: ARFocus?
        var focusBinding: Binding<ARFocus?> = .constant(nil)
        var readyBinding: Binding<Bool> = .constant(true)
        /// Whether the camera is showing, mirrored into `readyBinding` only when it changes.
        private var ready = false {
            didSet {
                guard ready != oldValue else { return }
                let ready = ready, binding = readyBinding
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25)) { binding.wrappedValue = ready } }
            }
        }
        /// The lines on screen as last drawn, for taps: which branch each belongs to.
        private var tapLines: [(focus: ARFocus, from: SIMD3<Float>, to: SIMD3<Float>)] = []

        func setFocus(_ new: ARFocus?) {
            guard new != focus else { return }
            focus = new
            render(animated: true)
        }
        /// Moves glide over about one tracking interval, so 10 updates a second look continuous.
        private let glide: TimeInterval = 0.1

        private var wordObjects: [String: (signature: String, node: SCNNode)] = [:]
        private var personaObjects: [String: (signature: String, node: SCNNode)] = [:]
        private var rootObjects: [Int: (signature: String, node: SCNNode)] = [:]
        private var linkObjects: [String: SCNNode] = [:]  // tubes, dashes, meaning labels
        private let links = SCNNode()

        // MARK: session

        func setRunning(_ run: Bool) {
            guard run != running, let view else { return }
            running = run
            if run {
                startSession()
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                UprightLabel.follow(view.pointOfView)
                if links.parent == nil { view.scene.rootNode.addChildNode(links) }
            } else {
                watchdog?.invalidate(); watchdog = nil
                view.session.pause()
                ready = false
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }

        /// When the last camera frame arrived; the watchdog restarts a session that gets none.
        private var lastFrame = Date.distantPast
        private var started = Date.distantPast
        private var watchdog: Timer?

        private func startSession() {
            guard let view else { return }
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]  // better hits on walls and signs
            view.session.run(config)
            ready = false
            started = Date()
            // Coming from Camera, its capture session lets go of the camera only after this
            // session has started, and then ARKit shows black until it is run again.
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    let now = Date()
                    if now.timeIntervalSince(self.lastFrame) > 1.0,
                       now.timeIntervalSince(self.started) > 1.0 {
                        self.startSession()
                    }
                }
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            MainActor.assumeIsolated { if running { startSession() } }
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            MainActor.assumeIsolated { if running { startSession() } }
        }

        private var hadWords = false

        /// The scene was emptied (Clear): forget where its words were. Not while it is
        /// merely still empty: words being confirmed already have anchors.
        func sceneIsEmpty(_ empty: Bool) {
            if empty, hadWords { anchors = [:] }
            hadWords = !empty
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // delegate calls arrive on the main queue (no delegateQueue set)
            MainActor.assumeIsolated {
                lastFrame = Date()
                ready = true
                // who is talking is watched even while the phone moves: faces don't blur like text
                if let conversation, conversation.listening {
                    conversation.locator.consider(frame, session: session)
                }
                consider(frame)
            }
        }

        // MARK: conversation

        private weak var conversation: Conversation?

        func listen(to conversation: Conversation) {
            guard self.conversation !== conversation else {
                render(animated: true)  // someone spoke: their words and place
                return
            }
            self.conversation = conversation
            conversation.locator.onUpdate = { [weak self, weak conversation] in
                // a face moved: its persona and words go with it
                if conversation?.follow() == true { self?.render(animated: true) }
            }
        }

        /// How the phone is held, as Vision should read the camera image. The app's screens
        /// stay portrait; this follows the phone itself (face up or down keeps the last).
        private var orientation: CGImagePropertyOrientation = .right

        private func followOrientation() {
            UprightLabel.follow(view?.pointOfView)  // the camera node labels face, once it exists
            guard let held = ARGeometry.imageOrientation(for: UIDevice.current.orientation),
                  held != orientation else { return }
            orientation = held
            UprightLabel.set(roll: ARGeometry.labelRoll(for: held))
        }

        private func consider(_ frame: ARFrame) {
            followOrientation()
            let now = Date()
            let moving = lastCamera.map {
                ARGeometry.isMoving(from: $0.transform, to: frame.camera.transform,
                                    seconds: frame.timestamp - $0.time)
            } ?? true
            lastCamera = (frame.camera.transform, frame.timestamp)
            // a moving phone gives blurred text and poor positions, and reading then takes
            // time from tracking exactly when it matters: wait until it is held steady
            guard !moving, case .normal = frame.camera.trackingState else { return }
            let orientation = self.orientation
            let camera = (intrinsics: frame.camera.intrinsics, resolution: frame.camera.imageResolution,
                          transform: frame.camera.transform, time: frame.timestamp,
                          orientation: orientation)

            if reading, !fullBusy, now.timeIntervalSince(lastFull) >= fullInterval {
                // a copy: the session has only a few camera buffers, and holding one for the
                // whole read (a few hundred ms) makes it drop frames
                guard let buffer = ARGeometry.copy(frame.capturedImage) else { return }
                fullBusy = true
                lastFull = now
                fullQueue.async { [weak self] in
                    // read the way the phone is held: text is upright in portrait and landscape
                    let recognition = (try? WordExtractor.recognize(in: buffer, orientation: orientation, fast: false))
                        ?? Recognition()
                    let fast = WordExtractor.fastReads(recognition.text)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.fullBusy = false
                        self.trackFast = fast
                        self.place(recognition, camera: camera, onlyKnown: false)
                        let upright = ARGeometry.uprightSize(camera.resolution, orientation: orientation)
                        self.onRead(Read(recognition: recognition, imageSize: upright,
                                         picture: .buffer(buffer, orientation)))
                    }
                }
            } else if !trackBusy, !anchors.isEmpty, now.timeIntervalSince(lastTrack) >= trackInterval {
                // tracking goes on while held: no new words, but the tags keep following
                guard let buffer = ARGeometry.copy(frame.capturedImage) else { return }
                trackBusy = true
                lastTrack = now
                let fast = trackFast
                trackQueue.async { [weak self] in
                    let recognition = (try? WordExtractor.recognize(in: buffer, orientation: orientation, fast: fast))
                        ?? Recognition()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.trackBusy = false
                        self.place(recognition, camera: camera, onlyKnown: true)
                    }
                }
            }
        }

        typealias Camera = (intrinsics: simd_float3x3, resolution: CGSize, transform: simd_float4x4,
                            time: TimeInterval, orientation: CGImagePropertyOrientation)

        /// Anchors every word of a read where its ray from the camera (as it was when the
        /// frame was taken) meets a surface; with no surface found, at the distance of the
        /// other words of the same read, or an arm's length. A tracking read (`onlyKnown`)
        /// only moves words already placed. A read of an older frame than a word's last
        /// position (a careful read finishing after quicker ones) leaves that word alone.
        private func place(_ recognition: Recognition, camera: Camera, onlyKnown: Bool) {
            guard let session = view?.session, !recognition.words.isEmpty else { return }
            let now = Date()
            let intrinsics = camera.intrinsics, resolution = camera.resolution, transform = camera.transform
            var hits: [(key: String, p: SIMD3<Float>, d: Float)] = []
            var misses: [(key: String, origin: SIMD3<Float>, direction: SIMD3<Float>)] = []
            for word in recognition.words {
                if let known = anchors[word.key] {
                    if known.frame > camera.time { continue }
                } else if onlyKnown {
                    continue
                }
                let center = CGPoint(x: word.box.midX, y: word.box.midY)
                let ray = ARGeometry.ray(through: ARGeometry.sensorPoint(upright: center, orientation: camera.orientation),
                                         intrinsics: intrinsics, resolution: resolution,
                                         cameraTransform: transform)
                let query = ARRaycastQuery(origin: ray.origin, direction: ray.direction,
                                           allowing: .estimatedPlane, alignment: .any)
                if let hit = session.raycast(query).first {
                    let c = hit.worldTransform.columns.3
                    let p = SIMD3(c.x, c.y, c.z)
                    hits.append((word.key, p, simd_distance(p, ray.origin)))
                } else {
                    misses.append((word.key, ray.origin, ray.direction))
                }
            }
            guard !hits.isEmpty || !misses.isEmpty else { return }
            let fallback = hits.isEmpty
                ? misses.compactMap { anchors[$0.key]?.distance }.first ?? 0.7
                : hits.map(\.d).sorted()[hits.count / 2]
            for miss in misses {
                // a word already placed keeps its distance: it moved sideways, not away
                let d = anchors[miss.key]?.distance ?? fallback
                hits.append((miss.key, miss.origin + miss.direction * d, d))
            }
            for hit in hits {
                // nudge toward the camera so the marker isn't buried in the surface
                let origin = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                let p = hit.p + simd_normalize(origin - hit.p) * 0.01
                if anchors[hit.key] != nil {
                    anchors[hit.key]!.update(to: p, distance: hit.d, at: now, frame: camera.time)
                } else {
                    anchors[hit.key] = ARWordAnchor(position: p, distance: hit.d, seen: now, frame: camera.time)
                }
            }
            if !onlyKnown {
                // words read but never part of the scene don't pile up
                let scene = Set(response?.words.map(\.key) ?? [])
                anchors = anchors.filter { scene.contains($0.key) || now.timeIntervalSince($0.value.seen) < 10 }
            }
            render(animated: true)
        }

        // MARK: drawing

        func show(_ response: SceneResponse?) {
            self.response = response
            render(animated: false)
        }

        /// Redraws only when what is shown changed: SwiftUI calls in often (loading, status),
        /// and rebuilding the scene each time costs frames. Everything already on screen is
        /// moved in place; `animated` glides it there (tracking updates), so tags follow a
        /// moving object smoothly rather than in steps.
        private func render(animated: Bool) {
            guard let view else { return }
            let root = view.scene.rootNode
            let personas = conversation?.personas ?? []
            var placed = anchors
            if let conversation, let camera = lastCamera?.transform ?? view.session.currentFrame?.camera.transform {
                // spoken words float by their speaker; a word also read in the room stays there
                let scene = Set(response?.words.map(\.key) ?? [])
                placed.merge(conversation.anchors(camera: camera, scene: scene)) { read, _ in read }
            }
            let layout = response.map { ARNetworkLayout(response: $0, anchors: placed) }

            // a picked branch: only it is shown; one whose words left the scene lets go
            var branch: ARBranchLayout?
            if case .root(let meet) = focus, let response, let layout {
                branch = ARBranchLayout(meet: meet, response: response, layout: layout)
            }
            let focusArc = layout?.arcs.first { focus == .meaning($0.id) }
            if focus != nil, branch == nil, focusArc == nil {
                focus = nil
                DispatchQueue.main.async { [weak self] in self?.focusBinding.wrappedValue = nil }
            }
            let shownWords: Set<Int>? = branch.map { Set($0.words) } ?? focusArc.map { [$0.a, $0.b] }

            let signature = "focus:\(String(describing: focus))|" + (layout?.signature ?? "")
                + (response?.words.map { "\($0.text)|\($0.lang ?? "")|\($0.terms.first ?? 0)" }
                    .joined(separator: ";") ?? "")
                + personas.map { "\($0.id)|\($0.title)|\($0.lang ?? "")|\($0.words.count)|"
                    + "\(Int($0.position.x * 200)),\(Int($0.position.y * 200)),\(Int($0.position.z * 200))" }
                    .joined(separator: ";")
            guard signature != drawn else { return }
            drawn = signature

            SCNTransaction.begin()
            if animated {
                SCNTransaction.animationDuration = glide
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            } else {
                SCNTransaction.disableActions = true
            }
            defer { SCNTransaction.commit() }

            var keepWords = Set<String>()
            for word in layout.map({ Array($0.words.values) }) ?? [] {
                guard let response else { break }
                let w = response.words[word.index]
                let language = w.terms.first.flatMap { response.node($0)?.language } ?? w.lang ?? ""
                let speaker = conversation?.persona(saying: word.key)
                let signature = "\(w.text)|\(language)|\(word.linked)|\(speaker?.id ?? "")"
                keepWords.insert(word.key)
                if wordObjects[word.key]?.signature != signature {
                    let old = wordObjects[word.key]?.node
                    old?.removeFromParentNode()
                    let node = Self.wordNode(key: word.key, text: w.text, language: language,
                                             linked: word.linked, speaker: speaker?.color)
                    // a replaced card starts where the old one was and glides on from there
                    node.simdPosition = old?.simdPosition ?? word.position
                    node.simdScale = old?.simdScale ?? SIMD3(repeating: word.scale)
                    root.addChildNode(node)
                    wordObjects[word.key] = (signature, node)
                }
                let node = wordObjects[word.key]!.node
                node.simdPosition = word.position
                node.simdScale = SIMD3(repeating: word.scale)
                node.opacity = shownWords.map { $0.contains(word.index) } ?? true ? 1 : 0
            }
            for (key, object) in wordObjects where !keepWords.contains(key) {
                object.node.removeFromParentNode()
                wordObjects[key] = nil
            }

            var keepPersonas = Set<String>()
            for p in personas {
                let label = "\(p.title)" + (p.lang.map { " · \(Self.languageName($0))" } ?? "")
                let signature = "\(label)|\(p.symbol)"
                keepPersonas.insert(p.id)
                if personaObjects[p.id]?.signature != signature {
                    let old = personaObjects[p.id]?.node
                    old?.removeFromParentNode()
                    let node = Self.personaNode(label, color: p.color)
                    node.simdPosition = old?.simdPosition ?? p.position
                    root.addChildNode(node)
                    personaObjects[p.id] = (signature, node)
                }
                let node = personaObjects[p.id]!.node
                // just above the head (or on the device), under the words they said
                node.simdPosition = p.position + SIMD3(0, 0.1 * max(p.distance, 0.5), 0)
                node.simdScale = SIMD3(repeating: max(p.distance, 0.5))
            }
            for (id, object) in personaObjects where !keepPersonas.contains(id) {
                object.node.removeFromParentNode()
                personaObjects[id] = nil
            }

            var keepRoots = Set<Int>()
            for r in layout?.roots ?? [] {
                guard let n = response?.node(r.node) else { continue }
                let signature = "\(n.word)|\(n.language)|\(r.meaning ?? "")"
                keepRoots.insert(r.node)
                if rootObjects[r.node]?.signature != signature {
                    let old = rootObjects[r.node]?.node
                    old?.removeFromParentNode()
                    let node = Self.rootNode(n, meaning: r.meaning)
                    node.simdPosition = old?.simdPosition ?? r.position
                    node.simdScale = old?.simdScale ?? SIMD3(repeating: r.scale)
                    root.addChildNode(node)
                    rootObjects[r.node] = (signature, node)
                }
                let node = rootObjects[r.node]!.node
                // a picked root rises to make room for the ancestors on the way up to it
                node.simdPosition = branch?.meet == r.node ? branch!.rootPosition : r.position
                node.simdScale = SIMD3(repeating: r.scale)
                node.opacity = focus == nil || focus == .root(r.node) ? 1 : 0
            }
            for (id, object) in rootObjects where !keepRoots.contains(id) {
                object.node.removeFromParentNode()
                rootObjects[id] = nil
            }

            var keepLinks = Set<String>()
            /// A link by id: made if new and placed straight away (no glide in from the
            /// origin), moved in place (gliding) if it was already there.
            func link(_ id: String, make: () -> SCNNode, update: (SCNNode) -> Void) {
                keepLinks.insert(id)
                if let node = linkObjects[id] {
                    update(node)
                    return
                }
                let node = make()
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                update(node)
                SCNTransaction.commit()
                links.addChildNode(node)
                linkObjects[id] = node
            }
            tapLines = []

            if let branch {
                // the picked root's branch: every ancestor on the way, coloured by how
                // each step was taken (inherited, borrowed…)
                for seg in branch.segments {
                    link("b:\(seg.id):\(seg.kind ?? "")", make: { Self.tube(color: Self.color(kind: seg.kind)) }) {
                        Self.stretch($0, from: seg.from, to: seg.to, radius: 0.0025 * seg.scale)
                    }
                    tapLines.append((.root(branch.meet), seg.from, seg.to))
                }
                for card in branch.cards {
                    guard let n = response?.node(card.node) else { continue }
                    link("c:\(card.node)", make: { Self.ancestorNode(n) }) {
                        $0.simdPosition = card.position
                        $0.simdScale = SIMD3(repeating: card.scale)
                    }
                }
            }

            let gold = Self.color(kind: nil)
            for r in layout?.roots ?? [] where focus == nil {
                let bottom = r.position - SIMD3(0, 0.035 * r.scale, 0)  // under the card
                for i in r.words {
                    guard let w = layout?.words[i] else { continue }
                    link("t:\(r.node):\(w.key)", make: { Self.tube(color: gold) }) {
                        Self.stretch($0, from: w.position, to: bottom, radius: 0.0025 * r.scale)
                    }
                    tapLines.append((.root(r.node), w.position, bottom))
                }
            }
            for arc in layout?.arcs ?? [] where focus == nil || focus == .meaning(arc.id) {
                guard let a = layout?.words[arc.a], let b = layout?.words[arc.b] else { continue }
                let id = "\(a.key)=\(b.key)"
                let scale = (a.scale + b.scale) / 2
                // below the word cards, sagging with the gap
                let dip = SIMD3<Float>(0, -(0.07 * scale + 0.25 * simd_distance(a.position, b.position)), 0)
                let from = a.position + SIMD3(0, -0.06 * a.scale, 0)
                let to = b.position + SIMD3(0, -0.06 * b.scale, 0)
                let control = (from + to) / 2 + dip
                let points = (0...16).map { k -> SIMD3<Float> in
                    let t = Float(k) / 16
                    return (1 - t) * (1 - t) * from + 2 * (1 - t) * t * control + t * t * to
                }
                for k in 0..<16 {
                    tapLines.append((.meaning(arc.id), points[k], points[k + 1]))
                    guard k.isMultiple(of: 2) else { continue }  // every other segment: dashed
                    link("a:\(id):\(k)", make: { Self.tube(color: .systemGreen) }) {
                        Self.stretch($0, from: points[k], to: points[k + 1], radius: 0.002 * scale)
                    }
                }
                link("l:\(id):\(arc.meaning)", make: {
                    let node = SCNNode(geometry: Self.meaningPlane(arc.meaning))
                    node.constraints = [UprightLabel.constraint()]
                    return node
                }) {
                    $0.simdPosition = (from + to) / 2 + dip / 2 + SIMD3(0, -0.02 * scale, 0)
                    $0.simdScale = SIMD3(repeating: scale)
                }
            }
            for (id, node) in linkObjects where !keepLinks.contains(id) {
                node.removeFromParentNode()
                linkObjects[id] = nil
            }
        }

        /// A dot on the word, its card just below; sized for 1 m away, scaled by distance.
        /// A spoken word's dot is its speaker's colour, and its card is edged with it.
        private static func wordNode(key: String, text: String, language: String, linked: Bool,
                                     speaker: UIColor? = nil) -> SCNNode {
            let node = SCNNode()
            node.name = "w:\(key)"
            let dot = SCNNode(geometry: SCNSphere(radius: speaker == nil ? 0.007 : 0.009))
            let color: UIColor = speaker ?? (linked ? .systemYellow : UIColor(white: 1, alpha: 0.8))
            dot.geometry?.firstMaterial?.diffuse.contents = color
            dot.geometry?.firstMaterial?.emission.contents = color.withAlphaComponent(0.6)
            node.addChildNode(dot)
            let card = SCNNode(geometry: SceneLabel.plane(
                word: text, language: language, reconstructed: false,
                fill: linked ? UIColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 1) : UIColor(white: 0.85, alpha: 1),
                pointsPerUnit: 1800))
            card.simdPosition = SIMD3(0, -0.035, 0)
            card.opacity = linked ? 1 : 0.7
            card.constraints = [UprightLabel.constraint()]
            if let speaker, let plane = card.geometry as? SCNPlane {
                // a band of the speaker's colour behind the card
                let band = SCNNode(geometry: SCNPlane(width: plane.width + 0.008, height: plane.height + 0.008))
                band.geometry?.firstMaterial?.diffuse.contents = speaker
                band.geometry?.firstMaterial?.lightingModel = .constant
                band.geometry?.firstMaterial?.isDoubleSided = true
                band.simdPosition = SIMD3(0, 0, -0.001)
                card.addChildNode(band)
            }
            node.addChildNode(card)
            return node
        }

        /// The speaker's tag: who (person, device, voice) and the language they speak.
        private static func personaNode(_ label: String, color: UIColor) -> SCNNode {
            let node = SCNNode()
            let text = label as NSString
            let font = UIFont.systemFont(ofSize: 24, weight: .bold)
            let size = text.size(withAttributes: [.font: font])
            let pill = CGSize(width: size.width + 28, height: size.height + 10)
            let image = UIGraphicsImageRenderer(size: pill).image { _ in
                color.withAlphaComponent(0.92).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: pill), cornerRadius: pill.height / 2).fill()
                text.draw(at: CGPoint(x: 14, y: 5), withAttributes: [.font: font, .foregroundColor: UIColor.white])
            }
            let plane = SCNPlane(width: pill.width / 1800, height: pill.height / 1800)
            plane.firstMaterial?.diffuse.contents = image
            plane.firstMaterial?.lightingModel = .constant
            plane.firstMaterial?.isDoubleSided = true
            let tag = SCNNode(geometry: plane)
            tag.constraints = [UprightLabel.constraint()]
            node.addChildNode(tag)
            return node
        }

        static func languageName(_ code: String) -> String {
            code == "sh" ? "Serbo-Croatian" : Locale.current.localizedString(forLanguageCode: code) ?? code
        }

        /// The colour of a step in a word's history, as in Explore: borrowings orange,
        /// links to a bare root grey, inheritance gold.
        static func color(kind: String?) -> UIColor {
            switch kind {
            case "borrowed", "learned", "calque", "semantic_loan": return .systemOrange
            case "root": return .systemGray
            default: return UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
            }
        }

        /// An ancestor on the way up a picked branch: a smaller, paler card than the root's.
        private static func ancestorNode(_ n: Node) -> SCNNode {
            let node = SCNNode()
            node.name = "r:\(n.id)"  // tapped: its details, like any term
            let card = SCNNode(geometry: SceneLabel.plane(
                word: n.word, language: n.language, reconstructed: n.reconstructed,
                fill: UIColor(red: 1.0, green: 0.96, blue: 0.82, alpha: 1), pointsPerUnit: 1800))
            card.constraints = [UprightLabel.constraint()]
            node.addChildNode(card)
            return node
        }

        private static func rootNode(_ n: Node, meaning: String?) -> SCNNode {
            let node = SCNNode()
            node.name = "r:\(n.id)"
            let card = SCNNode(geometry: SceneLabel.plane(
                word: n.word, language: n.language, meaning: meaning, reconstructed: n.reconstructed,
                fill: UIColor(red: 1.0, green: 0.92, blue: 0.62, alpha: 1), pointsPerUnit: 1400))
            card.constraints = [UprightLabel.constraint()]
            node.addChildNode(card)
            return node
        }

        private static func meaningPlane(_ meaning: String) -> SCNPlane {
            let text = "= \(meaning)" as NSString
            let font = UIFont.systemFont(ofSize: 26, weight: .semibold)
            let size = text.size(withAttributes: [.font: font])
            let card = CGSize(width: size.width + 24, height: size.height + 8)
            let image = UIGraphicsImageRenderer(size: card).image { _ in
                UIColor.systemGreen.withAlphaComponent(0.9).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: card), cornerRadius: card.height / 2).fill()
                text.draw(at: CGPoint(x: 12, y: 4), withAttributes: [.font: font, .foregroundColor: UIColor.white])
            }
            let plane = SCNPlane(width: card.width / 1800, height: card.height / 1800)
            plane.firstMaterial?.diffuse.contents = image
            plane.firstMaterial?.lightingModel = .constant
            plane.firstMaterial?.isDoubleSided = true
            return plane
        }

        private static func tube(color: UIColor) -> SCNNode {
            let cylinder = SCNCylinder(radius: 0.002, height: 0.01)
            cylinder.firstMaterial?.diffuse.contents = color
            cylinder.firstMaterial?.emission.contents = color.withAlphaComponent(0.4)
            return SCNNode(geometry: cylinder)
        }

        /// Lays a tube from `a` to `b`. Inside a transaction, so it glides with its ends.
        private static func stretch(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float) {
            guard let cylinder = node.geometry as? SCNCylinder else { return }
            let d = b - a
            let length = simd_length(d)
            cylinder.radius = CGFloat(radius)
            cylinder.height = CGFloat(length)
            node.simdPosition = (a + b) / 2
            if length > 0.0001 {
                // a cylinder runs along y: turn y onto the link
                node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: d / length)
            }
        }

        // MARK: taps

        /// A card (word, root, ancestor) opens its details. Otherwise the nearest line picks
        /// out its branch; a tap on nothing, with a branch picked out, shows everything again.
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view, let response else { return }
            let point = gesture.location(in: view)
            for hit in view.hitTest(point, options: nil) {
                var n: SCNNode? = hit.node
                var shown = true
                var target: GraphLayout.Key?
                while let current = n {
                    if current.opacity < 0.05 { shown = false }  // faded out with its branch
                    if target == nil, let name = current.name {
                        if name.hasPrefix("w:"),
                           let i = response.words.firstIndex(where: { $0.key == name.dropFirst(2) }) {
                            target = .word(i)
                        } else if name.hasPrefix("r:"), let id = Int(name.dropFirst(2)) {
                            target = .term(id)
                        }
                    }
                    n = current.parent
                }
                if shown, let target {
                    onSelect(target)
                    return
                }
            }

            if let picked = nearestLine(to: point, in: view) {
                guard picked != focus else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                focusBinding.wrappedValue = picked
                setFocus(picked)
            } else if focus != nil {
                focusBinding.wrappedValue = nil
                setFocus(nil)
            }
        }

        /// The branch of the line drawn nearest a tap, within a fingertip.
        private func nearestLine(to point: CGPoint, in view: ARSCNView) -> ARFocus? {
            func screen(_ p: SIMD3<Float>) -> CGPoint? {
                let s = view.projectPoint(SCNVector3(p))
                guard s.z > 0, s.z < 1 else { return nil }  // behind the camera
                return CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
            }
            var best: (focus: ARFocus, distance: CGFloat)?
            for line in tapLines {
                guard let a = screen(line.from), let b = screen(line.to) else { continue }
                let d = ARGeometry.distance(from: point, toSegment: a, b)
                if d < (best?.distance ?? 30) { best = (line.focus, d) }
            }
            return best?.focus
        }
    }
}

/// Who is talking: a chip per persona (their colour, where they are, their language), a
/// listening light, and the latest thing said, as a caption.
private struct ConversationOverlay: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if conversation.listening || !conversation.personas.isEmpty || conversation.error != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if conversation.listening {
                            Label(conversation.connecting ? "Loading voices…" : "Listening",
                                  systemImage: conversation.talking ? "waveform" : "mic.fill")
                                .symbolEffect(.variableColor, isActive: conversation.talking)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        ForEach(conversation.personas) { p in
                            Label(p.title + (p.lang.map { " · \($0)" } ?? ""), systemImage: p.symbol)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(.white)
                                .background(Color(p.color), in: Capsule())
                                .accessibilityIdentifier("persona-\(p.id)")
                        }
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                }
                .padding(.top, 8)
                if let error = conversation.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.white)
                        .padding(8).background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12)
                }
            }
            Spacer()
            if let caption = conversation.caption,
               let p = conversation.personas.first(where: { $0.id == caption.persona }) {
                (Text(p.title + ": ").bold().foregroundColor(Color(p.color)) + Text(caption.text))
                    .font(.callout)
                    .lineLimit(2)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 64)  // above the buttons
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Shown while ARKit starts the camera, instead of a black screen.
private struct ARStarting: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(systemName: "arkit")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
                ProgressView().tint(.white)
                Text("Starting AR…")
                    .font(.headline).foregroundStyle(.white)
                Text("Point the camera at some text.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("arStarting")
    }
}
