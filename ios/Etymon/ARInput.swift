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

    static var isAvailable: Bool { ARWorldTrackingConfiguration.isSupported }

    var body: some View {
        if Self.isAvailable {
            ZStack(alignment: .bottomTrailing) {
                ARNetworkView(response: model.response?.showing(layers),
                              sceneIsEmpty: model.words.isEmpty, reading: !paused && !exploring,
                              running: !exploring, conversation: conversation,
                              personas: conversation.personas, onSelect: onSelect) { read in
                    model.see(read.recognition, imageSize: read.imageSize, full: true,
                              picture: read.picture)
                }
                .accessibilityIdentifier("arView")
                ConversationOverlay(conversation: conversation)
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
            .onChange(of: model.words.isEmpty) { _, empty in if empty { conversation.clearWords() } }
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
                let config = ARWorldTrackingConfiguration()
                config.planeDetection = [.horizontal, .vertical]  // better hits on walls and signs
                view.session.run(config)
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                UprightLabel.follow(view.pointOfView)
                if links.parent == nil { view.scene.rootNode.addChildNode(links) }
            } else {
                view.session.pause()
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
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
            let signature = (layout?.signature ?? "")
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
                node.simdPosition = r.position
                node.simdScale = SIMD3(repeating: r.scale)
            }
            for (id, object) in rootObjects where !keepRoots.contains(id) {
                object.node.removeFromParentNode()
                rootObjects[id] = nil
            }

            var keepLinks = Set<String>()
            func link(_ id: String, make: () -> SCNNode) -> SCNNode {
                keepLinks.insert(id)
                if let node = linkObjects[id] { return node }
                let node = make()
                links.addChildNode(node)
                linkObjects[id] = node
                return node
            }
            let gold = UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
            for r in layout?.roots ?? [] {
                let bottom = r.position - SIMD3(0, 0.035 * r.scale, 0)  // under the card
                for i in r.words {
                    guard let w = layout?.words[i] else { continue }
                    let tube = link("t:\(r.node):\(w.key)") { Self.tube(color: gold) }
                    Self.stretch(tube, from: w.position, to: bottom, radius: 0.0025 * r.scale)
                }
            }
            for arc in layout?.arcs ?? [] {
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
                for k in stride(from: 0, to: 16, by: 2) {  // every other segment: dashed
                    let dash = link("a:\(id):\(k)") { Self.tube(color: .systemGreen) }
                    Self.stretch(dash, from: points[k], to: points[k + 1], radius: 0.002 * scale)
                }
                let label = link("l:\(id):\(arc.meaning)") {
                    let node = SCNNode(geometry: Self.meaningPlane(arc.meaning))
                    node.constraints = [UprightLabel.constraint()]
                    node.simdPosition = (from + to) / 2 + dip / 2
                    return node
                }
                label.simdPosition = (from + to) / 2 + dip / 2 + SIMD3(0, -0.02 * scale, 0)
                label.simdScale = SIMD3(repeating: scale)
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

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view, let response else { return }
            for hit in view.hitTest(gesture.location(in: view), options: nil) {
                var n: SCNNode? = hit.node
                while let current = n {
                    if let name = current.name {
                        if name.hasPrefix("w:"),
                           let i = response.words.firstIndex(where: { $0.key == name.dropFirst(2) }) {
                            onSelect(.word(i))
                            return
                        }
                        if name.hasPrefix("r:"), let id = Int(name.dropFirst(2)) {
                            onSelect(.term(id))
                            return
                        }
                    }
                    n = current.parent
                }
            }
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
