import SceneKit
import SwiftUI

/// Explore: the word network behind the scene, in 3D. The words that were seen sit on the
/// ground, their ancestors rise above them (older = higher), descendants hang below. Drag
/// to orbit, pinch to zoom; tap a node to fly to it and see its details; press and hold a
/// node to move it; Expand brings in where it comes from and what came from it.
struct ExploreView: View {
    let graph: ExploreGraph
    /// Talk shows the same space, growing: its own title, no Back, the camera following.
    var title = "Explore"
    var follow = false
    var emptyHint = "Tap a word to explore it — or start from one seen in the scene:"
    /// Talk: only these speakers' words (and their trees); empty shows everyone.
    var speakers: Set<Int> = []
    /// Talk has its own controls (and counts) where the header would be.
    var showsHeader = true
    var onClose: (() -> Void)?
    @AppStorage(TreeDepth.storageKey) private var treeDepth = TreeDepth.defaultValue
    @AppStorage(ExploreScope.storageKey) private var scope: ExploreScope = .whole

    @State private var selected: Int?
    @State private var expanding: Int?
    @State private var error: String?
    @State private var lineage: ExploreGraph.XNode?

    /// How much of the screen the panel takes. Drag its handle (or tap it) to change.
    enum Detent: CaseIterable {
        case collapsed, peek, expanded
        /// Share of the screen for the panel's scrolling part; collapsed shows none.
        var share: CGFloat {
            switch self {
            case .collapsed: return 0
            case .peek: return 0.26
            case .expanded: return 0.62
            }
        }
    }

    @State private var detent: Detent = .peek
    @State private var drag: CGFloat = 0  // live drag of the handle, points (up = positive)
    @State private var bodyHeight: CGFloat = 0  // natural height of the scrolling content

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                NetworkScene(graph: graph, version: graph.version, depth: treeDepth, speakers: speakers,
                             scope: scope,
                             follow: follow, selected: $selected)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("explore3D")

                VStack(spacing: 0) {
                    if showsHeader { header }
                    Spacer(minLength: 0)
                    panel(screen: geo.size.height)
                }
            }
        }
        .background(Color(red: 0.05, green: 0.06, blue: 0.1))
        .environment(\.colorScheme, .dark)
        .onAppear {
            // Talk: the space first, the panel when a word is picked
            if follow { detent = .collapsed }
        }
        .onChange(of: selected) { _, id in
            // picking a word in the tree brings its details up
            if id != nil, detent == .collapsed { withAnimation(.snappy) { detent = .peek } }
        }
        .sheet(item: $lineage) { node in
            NavigationStack { WordDetail(text: node.label, lang: node.lang) }
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack {
            if let onClose {
                Button(action: onClose) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("closeExplore")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(title).font(.headline)
                Text("\(graph.nodes.count) words · \(graph.edges.count) links")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ExploreScopeMenu()
                    TreeDepthMenu()
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    // MARK: panel

    /// A bottom sheet over the tree: a handle to drag, the selected word and its actions
    /// (always visible), then the lists, which scroll inside the panel instead of growing
    /// it. Collapsed, only the handle and the word remain, leaving the tree free.
    private func panel(screen: CGFloat) -> some View {
        let limit = detentHeight(.expanded, screen)
        let target = detentHeight(detent, screen)
        let height = min(max(target + drag, 0), limit)
        return VStack(alignment: .leading, spacing: 10) {
            handle(screen: screen)
            top
            if height > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { scrolling }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            bodyHeight = $0
                        }
                }
                .frame(height: min(height, bodyHeight))
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("explorePanelList")
            }
        }
        .padding([.horizontal, .bottom])
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func detentHeight(_ d: Detent, _ screen: CGFloat) -> CGFloat { screen * d.share }

    /// Drag up or down to resize; let go and it settles on the nearest size (a flick goes
    /// with the flick). Tap to switch between collapsed and open.
    private func handle(screen: CGFloat) -> some View {
        Capsule().fill(.secondary).frame(width: 40, height: 5)
            .frame(maxWidth: .infinity).frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { drag = -$0.translation.height }
                    .onEnded { value in
                        let current = detentHeight(detent, screen)
                        let predicted = current - value.predictedEndTranslation.height
                        let next = Detent.allCases.min {
                            abs(detentHeight($0, screen) - predicted) < abs(detentHeight($1, screen) - predicted)
                        } ?? detent
                        withAnimation(.snappy) {
                            detent = next
                            drag = 0
                        }
                    })
            .onTapGesture {
                withAnimation(.snappy) { detent = detent == .collapsed ? .peek : .collapsed }
            }
            .accessibilityElement()
            .accessibilityLabel(detent == .collapsed ? "Show panel" : "Hide panel")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                withAnimation(.snappy) { detent = detent == .collapsed ? .peek : .collapsed }
            }
            .accessibilityAdjustableAction { direction in
                let all = Detent.allCases, i = all.firstIndex(of: detent) ?? 1
                withAnimation(.snappy) {
                    switch direction {
                    case .increment: detent = all[min(i + 1, all.count - 1)]
                    case .decrement: detent = all[max(i - 1, 0)]
                    @unknown default: break
                    }
                }
            }
            .accessibilityIdentifier("explorePanelHandle")
            .padding(.bottom, -4)
    }

    /// Always shown: what is selected and what can be done with it.
    @ViewBuilder private var top: some View {
        if let id = selected, let node = graph.nodes[id] {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.label).font(.title2.bold()).italic(node.reconstructed)
                        .accessibilityIdentifier("exploreSelected")
                    Text(node.language + (role(node).map { " · " + $0 } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show all", systemImage: "circle.hexagongrid") { selected = nil }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("exploreShowAll")
            }
            if detent != .collapsed {
                actions(node)
            }
        } else {
            Text(emptyHint)
                .font(.subheadline)
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    /// The part that scrolls: the word's links, or the scene's words to start from.
    @ViewBuilder private var scrolling: some View {
        if let id = selected, let node = graph.nodes[id] {
            details(node)
        } else {
            chips(graph.sceneWords.compactMap { graph.nodes[$0] }.map { ($0, nil) })
            Text("Drag to turn · two fingers to move · pinch to zoom · press and hold a word to move it · "
                 + "drag the handle to resize this panel")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func actions(_ node: ExploreGraph.XNode) -> some View {
        HStack {
            Button {
                if node.expanded { graph.collapse(node.id) } else { Task { await expand(node.id) } }
            } label: {
                if expanding == node.id {
                    ProgressView().controlSize(.small)
                } else if node.expanded {
                    Label("Collapse", systemImage: "arrow.down.right.and.arrow.up.left")
                } else {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(node.expanded ? .gray : .accentColor)
            .disabled(expanding != nil)
            .accessibilityIdentifier(node.expanded ? "collapseNode" : "expandNode")
            Button("Lineage", systemImage: "list.bullet.indent") { lineage = node }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func details(_ node: ExploreGraph.XNode) -> some View {
        let links = graph.neighbors(of: node.id)
        if let gloss = node.gloss {
            Text(gloss).font(.subheadline)
        }
        if let seen = graph.origins[node.id], !seen.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("seen on").font(.caption).foregroundStyle(.secondary)
                ForEach(seen, id: \.self) { Label($0, systemImage: "mappin.and.ellipse").font(.caption) }
            }
            .accessibilityIdentifier("seenOn")
        }
        VStack(alignment: .leading, spacing: 8) {
            if !links.parents.isEmpty {
                section("comes from", links.parents.compactMap { e in graph.nodes[e.b].map { ($0, e.kind) } })
            }
            if !links.children.isEmpty {
                section("gave", links.children.compactMap { e in graph.nodes[e.a].map { ($0, e.kind) } })
            }
            if !links.meanings.isEmpty {
                section("same meaning", links.meanings.compactMap { e in
                    graph.nodes[e.a == node.id ? e.b : e.a].map { ($0, "= " + (e.meaning ?? "")) }
                })
            }
        }
        if let total = node.totalChildren, total > links.children.count {
            Text("\(total - links.children.count) more descendants in the dictionary")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, _ items: [(ExploreGraph.XNode, String?)]) -> some View {
        let shown = 8
        return VStack(alignment: .leading, spacing: 4) {
            Text(title + (items.count > shown ? "  (\(shown) of \(items.count))" : ""))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            chips(Array(items.prefix(shown)))
        }
    }

    /// Tappable words: tap to jump there.
    private func chips(_ items: [(ExploreGraph.XNode, String?)]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.0.id) { node, note in
                Button { selected = node.id } label: {
                    HStack(spacing: 4) {
                        Text(node.label).italic(node.reconstructed)
                        Text(note.map { "\(short($0)) · \(node.language)" } ?? node.language)
                            .font(.caption2).opacity(0.7)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color(NetworkScene.color(for: node, in: graph)).opacity(0.85)))
                    .foregroundStyle(.black)
                }
                .accessibilityIdentifier("jump-\(node.label)")
            }
        }
    }

    private func short(_ kind: String) -> String {
        switch kind {
        case "inherited": return "inherited"
        case "borrowed": return "borrowed"
        case "learned": return "learned"
        case "component": return "part"
        case "root": return "root"
        case "derived": return "from"
        default: return kind
        }
    }

    private func role(_ node: ExploreGraph.XNode) -> String? {
        switch node.role {
        case .scene: return graph.speakers[node.id].map { "said by Speaker \($0)" } ?? "seen in the scene"
        case .meeting: return "shared root"
        case .ancestor: return nil
        case .expanded: return nil
        }
    }

    private func expand(_ id: Int) async {
        expanding = id
        defer { expanding = nil }
        do {
            graph.expand(try await APIClient.fromSettings().neighbors(of: id))
            error = nil
        } catch {
            self.error = "Couldn't expand: \(error.localizedDescription)"
        }
    }
}

extension ExploreGraph.XNode: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

// MARK: - SceneKit

struct NetworkScene: UIViewRepresentable {
    let graph: ExploreGraph
    let version: Int  // structural changes trigger updateUIView
    /// Steps drawn between words and roots (TreeDepth), and whose words (Talk; empty: all).
    var depth = TreeDepth.all
    var speakers: Set<Int> = []
    /// The whole network, or only the paths that connect words.
    var scope = ExploreScope.whole
    /// Keep the whole network in view as it grows (until the user picks a word).
    var follow = false
    @Binding var selected: Int?

    /// A node's colour: a spoken word takes its speaker's.
    static func color(for node: ExploreGraph.XNode, in graph: ExploreGraph) -> UIColor {
        if node.role == .scene, let speaker = graph.speakers[node.id] {
            return speakerColor(speaker)
        }
        return UIColor(color(for: node.role))
    }

    static let speakerPalette: [UIColor] = [
        UIColor(red: 1.0, green: 0.45, blue: 0.62, alpha: 1), UIColor(red: 0.35, green: 0.85, blue: 0.9, alpha: 1),
        UIColor(red: 1.0, green: 0.62, blue: 0.3, alpha: 1), UIColor(red: 0.72, green: 0.55, blue: 1.0, alpha: 1),
        UIColor(red: 0.5, green: 0.9, blue: 0.55, alpha: 1), UIColor(red: 0.55, green: 0.7, blue: 1.0, alpha: 1),
    ]

    static func speakerColor(_ number: Int) -> UIColor {
        speakerPalette[(max(number, 1) - 1) % speakerPalette.count]
    }

    static func color(for role: ExploreGraph.Role) -> Color {
        switch role {
        case .scene: return Color(red: 0.55, green: 0.78, blue: 1.0)
        case .meeting: return Color(red: 1.0, green: 0.82, blue: 0.3)
        case .ancestor: return Color(red: 1.0, green: 0.92, blue: 0.62)
        case .expanded: return Color(red: 0.82, green: 0.82, blue: 0.86)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.pointOfView = context.coordinator.camera
        context.coordinator.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        let hold = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.3
        view.addGestureRecognizer(hold)
        // two fingers slide the view (pinch still zooms, one finger still turns)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        context.coordinator.sync(graph, depth: depth, speakers: speakers, scope: scope)
        context.coordinator.frameAll()
        context.coordinator.start()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.selectedBinding = $selected
        context.coordinator.follow = follow && selected == nil
        context.coordinator.sync(graph, depth: depth, speakers: speakers, scope: scope)
        context.coordinator.select(selected)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let scene = SCNScene()
        let camera = SCNNode()
        weak var view: SCNView?
        var selectedBinding: Binding<Int?>

        private let layout = ForceLayout()
        private var graph: ExploreGraph?
        private var nodeObjects: [Int: SCNNode] = [:]
        private var nodeStyles: [Int: String] = [:]  // role and colour each was drawn with
        private var skipLabels: [ExploreGraph.XEdge: SCNNode] = [:]  // "+3" on shortcuts
        var follow = false
        private var edgeObjects: [ExploreGraph.XEdge: SCNNode] = [:]
        private var syncedKey = ""
        private var currentSelection: Int?
        private var link: CADisplayLink?
        private var settleFrames = 0
        private var dragging: (id: Int, depth: Float)?

        init(selected: Binding<Int?>) {
            selectedBinding = selected
            super.init()
            camera.camera = SCNCamera()
            camera.camera?.zFar = 500
            camera.position = SCNVector3(0, 4, 18)
            scene.rootNode.addChildNode(camera)
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 500
            scene.rootNode.addChildNode(ambient)
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.intensity = 900
            key.position = SCNVector3(8, 20, 16)
            scene.rootNode.addChildNode(key)
            // the ground: where the words of the scene are
            let ground = SCNNode(geometry: SCNPlane(width: 60, height: 60))
            ground.eulerAngles.x = -.pi / 2
            ground.position.y = -0.9
            ground.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 1, alpha: 0.04)
            ground.geometry?.firstMaterial?.isDoubleSided = true
            scene.rootNode.addChildNode(ground)
        }

        // MARK: structure

        func sync(_ full: ExploreGraph, depth: Int, speakers: Set<Int>, scope: ExploreScope) {
            let focus = selectedBinding.wrappedValue
            let key = "\(ObjectIdentifier(full))|\(full.version)|\(depth)|\(speakers.sorted())|\(focus ?? -1)|\(scope.rawValue)"
            guard key != syncedKey else { return }
            syncedKey = key
            // what is drawn: the network cut to the steps and speakers asked for, and to the
            // picked word's tree
            let graph = full.shown(depth: depth, speakers: speakers, focus: focus, scope: scope)
            self.graph = graph
            layout.sync(graph)
            for (id, object) in nodeObjects where graph.nodes[id] == nil {
                object.removeFromParentNode()
                nodeObjects[id] = nil
                nodeStyles[id] = nil
                if id == currentSelection { currentSelection = nil }
            }
            for (e, object) in edgeObjects where !graph.edges.contains(e) {
                object.removeFromParentNode()
                edgeObjects[e] = nil
                skipLabels[e]?.removeFromParentNode()
                skipLabels[e] = nil
            }
            let grew = graph.nodes.count != nodeObjects.count
            for (id, node) in graph.nodes {
                // new, or restyled: an ancestor became a shared root, a word changed speaker
                let style = "\(node.role)|\(graph.speakers[id] ?? 0)"
                guard nodeStyles[id] != style else { continue }
                let old = nodeObjects[id]
                old?.removeFromParentNode()
                let object = makeNode(node)
                if let old { object.simdPosition = old.simdPosition }
                if node.role == .meeting, old != nil { Self.pulse(object) }
                nodeObjects[id] = object
                nodeStyles[id] = style
                scene.rootNode.addChildNode(object)
                if id == currentSelection { currentSelection = nil }
            }
            for e in graph.edges where edgeObjects[e] == nil {
                let object = makeEdge(e)
                edgeObjects[e] = object
                scene.rootNode.addChildNode(object)
                if e.skipped > 0 {
                    let label = Self.skipLabel(e.skipped)
                    skipLabels[e] = label
                    scene.rootNode.addChildNode(label)
                }
            }
            settleFrames = 240
            updatePositions()
            if follow, grew, !userMoved { frameAll(settle: false, animated: true) }
        }

        /// A new shared root swells and settles, so it catches the eye.
        private static func pulse(_ object: SCNNode) {
            let up = SCNAction.scale(to: 2.2, duration: 0.25)
            up.timingMode = .easeOut
            let down = SCNAction.scale(to: 1, duration: 0.6)
            down.timingMode = .easeInEaseOut
            object.runAction(.sequence([up, down]))
        }

        private func makeNode(_ node: ExploreGraph.XNode) -> SCNNode {
            let radius: CGFloat = node.role == .scene ? 0.24 : node.role == .meeting ? 0.22 : 0.15
            let sphere = SCNSphere(radius: radius)
            let color = graph.map { NetworkScene.color(for: node, in: $0) } ?? UIColor(NetworkScene.color(for: node.role))
            sphere.firstMaterial?.diffuse.contents = color
            sphere.firstMaterial?.emission.contents = UIColor.black
            let object = SCNNode(geometry: sphere)
            object.name = "n\(node.id)"
            let label = SCNNode(geometry: Self.labelPlane(node, fill: color))
            label.name = "n\(node.id)"
            label.position = SCNVector3(0, Float(radius) + 0.25, 0)
            label.constraints = [SCNBillboardConstraint()]
            object.addChildNode(label)
            return object
        }

        private func makeEdge(_ e: ExploreGraph.XEdge) -> SCNNode {
            if e.skipped > 0 {
                // hidden steps: a thin, faint line straight on to the root
                let cylinder = SCNCylinder(radius: 0.018, height: 1)
                cylinder.firstMaterial?.diffuse.contents = UIColor(white: 1, alpha: 1)
                cylinder.firstMaterial?.emission.contents = UIColor(white: 1, alpha: 0.3)
                let object = SCNNode(geometry: cylinder)
                object.opacity = 0.35
                return object
            }
            let cylinder = SCNCylinder(radius: e.isMeaning ? 0.035 : 0.045, height: 1)
            let color: UIColor = e.isMeaning ? .systemGreen
                : e.kind == "borrowed" || e.kind == "learned" || e.kind == "calque" ? .systemOrange
                : e.kind == "root" ? .systemGray : UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
            cylinder.firstMaterial?.diffuse.contents = color
            cylinder.firstMaterial?.emission.contents = color.withAlphaComponent(0.35)
            let object = SCNNode(geometry: cylinder)
            object.opacity = e.isMeaning ? 0.75 : 0.9
            return object
        }

        /// "+3 steps": how many steps a shortcut leaves out, at its middle.
        private static func skipLabel(_ count: Int) -> SCNNode {
            let text = (count == 1 ? "+1 step" : "+\(count) steps") as NSString
            let font = UIFont.systemFont(ofSize: 22, weight: .semibold)
            let size = text.size(withAttributes: [.font: font])
            let pill = CGSize(width: size.width + 18, height: size.height + 6)
            let image = UIGraphicsImageRenderer(size: pill).image { _ in
                UIColor(white: 0.25, alpha: 0.85).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: pill), cornerRadius: pill.height / 2).fill()
                text.draw(at: CGPoint(x: 9, y: 3), withAttributes: [.font: font, .foregroundColor: UIColor.white])
            }
            let plane = SCNPlane(width: pill.width / 170, height: pill.height / 170)
            plane.firstMaterial?.diffuse.contents = image
            plane.firstMaterial?.lightingModel = .constant
            plane.firstMaterial?.isDoubleSided = true
            let node = SCNNode(geometry: plane)
            node.constraints = [SCNBillboardConstraint()]
            return node
        }

        /// A word and its language on a plane that faces the camera.
        private static func labelPlane(_ node: ExploreGraph.XNode, fill: UIColor) -> SCNPlane {
            SceneLabel.plane(word: node.label, language: node.language,
                             reconstructed: node.reconstructed, fill: fill, pointsPerUnit: 170)
        }

        // MARK: motion

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func frame() {
            guard let graph, settleFrames > 0 || dragging != nil else { return }
            let moved = layout.step(graph)
            settleFrames -= 1
            if moved < 0.002 && dragging == nil { settleFrames = min(settleFrames, 10) }
            updatePositions()
        }

        private func updatePositions() {
            for (id, object) in nodeObjects {
                if let p = layout.positions[id] { object.simdPosition = p }
            }
            for (e, object) in edgeObjects {
                guard let a = layout.positions[e.a], let b = layout.positions[e.b] else { continue }
                let d = b - a
                let len = simd_length(d)
                object.simdPosition = (a + b) / 2
                skipLabels[e]?.simdPosition = (a + b) / 2
                (object.geometry as? SCNCylinder)?.height = CGFloat(len)
                if len > 0.0001 {
                    // a cylinder runs along y: rotate y onto the link's direction
                    object.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: d / len)
                }
            }
        }

        // MARK: camera

        /// Camera far enough back to see the whole network.
        func frameAll(settle: Bool = true, animated: Bool = false) {
            guard let graph else { return }
            if settle {
                for _ in 0..<200 { layout.step(graph) }  // start from a settled layout
                updatePositions()
            }
            let ids = Array(graph.nodes.keys)
            let center = layout.center(of: ids)
            // most of the network, not its farthest stray: a node or two far off (a loop in
            // the data, a long climb) shouldn't shrink everything else to dots
            let distances = ids.compactMap { layout.positions[$0] }.map { simd_length($0 - center) }.sorted()
            let radius = distances.isEmpty ? 5 : distances[min(distances.count - 1, Int(Float(distances.count) * 0.9))]
            if animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 1.2
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            camera.simdPosition = center + SIMD3(0, radius * 0.3, max(radius * 2.4, 10))
            camera.simdLook(at: center)
            if animated { SCNTransaction.commit() }
            view?.defaultCameraController.target = SCNVector3(center)
        }

        /// Fly to a node and orbit around it from now on.
        func focus(on id: Int) {
            guard let target = layout.positions[id] else { return }
            let offset = camera.simdPosition - (view.map { SIMD3<Float>($0.defaultCameraController.target) } ?? .zero)
            let distance: Float = 12
            let direction = simd_length(offset) > 0.01 ? simd_normalize(offset) : SIMD3(0, 0.2, 1)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.7
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            camera.simdPosition = target + direction * distance
            camera.simdLook(at: target)
            SCNTransaction.commit()
            view?.defaultCameraController.target = SCNVector3(target)
        }

        func select(_ id: Int?) {
            guard id != currentSelection else { return }
            if let old = currentSelection, let object = nodeObjects[old] {
                object.geometry?.firstMaterial?.emission.contents = UIColor.black
                object.scale = SCNVector3(1, 1, 1)
            }
            let hadSelection = currentSelection != nil
            currentSelection = id
            guard let id, let object = nodeObjects[id] else {
                // back to the whole network: step back to see all of it
                if id == nil, hadSelection { frameAll(settle: false, animated: true) }
                return
            }
            object.geometry?.firstMaterial?.emission.contents = UIColor(white: 0.6, alpha: 1)
            object.scale = SCNVector3(1.5, 1.5, 1.5)
            focus(on: id)
        }

        // MARK: gestures

        /// Set once the user slides the view: growing networks stop re-framing it.
        private var userMoved = false

        /// Two-finger drag: the camera and the point it turns around slide together, sideways
        /// and up or down on screen, as far as the fingers moved at the depth of that point.
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view, let pov = view.pointOfView else { return }
            let t = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            let target = SIMD3<Float>(view.defaultCameraController.target)
            let distance = max(simd_distance(pov.simdWorldPosition, target), 1)
            let fov = Float(pov.camera?.fieldOfView ?? 60) * .pi / 180
            let perPoint = 2 * distance * tan(fov / 2) / Float(max(view.bounds.height, 1))
            let delta = (-pov.simdWorldRight * Float(t.x) + pov.simdWorldUp * Float(t.y)) * perPoint
            pov.simdWorldPosition += delta
            view.defaultCameraController.target = SCNVector3(target + delta)
            userMoved = true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer
        }

        private func nodeID(at point: CGPoint) -> Int? {
            guard let view else { return nil }
            for hit in view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
                var n: SCNNode? = hit.node
                while let current = n {
                    if let name = current.name, name.hasPrefix("n"), let id = Int(name.dropFirst()) {
                        return id
                    }
                    n = current.parent
                }
            }
            return nil
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            selectedBinding.wrappedValue = nodeID(at: gesture.location(in: view))
        }

        /// Press and hold a node, then drag it: it stays where it is put, links follow.
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                guard let id = nodeID(at: point), let p = layout.positions[id] else { return }
                let projected = view.projectPoint(SCNVector3(p))
                dragging = (id, projected.z)
                layout.pinned.insert(id)
                view.allowsCameraControl = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .changed:
                guard let drag = dragging else { return }
                let world = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), drag.depth))
                layout.move(drag.id, to: SIMD3<Float>(world))
                settleFrames = 120
            default:
                dragging = nil
                view.allowsCameraControl = true
                settleFrames = 120
            }
        }
    }
}
