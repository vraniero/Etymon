import SwiftUI

/// The first screen: every mode, over the icon's tree come alive.
struct HomeView: View {
    let onOpen: (ContentView.Source) -> Void
    @State private var showLibrary = false
    @State private var showHelp = false
    @State private var showSettings = false
    @State private var showGames = LaunchOptions.game != nil
    @State private var appeared = false

    var body: some View {
        ZStack {
            // the tree and the title share one center, measured on the full screen
            GeometryReader { geo in
                RootsBackground(center: CGPoint(x: 0.5, y: Self.treeCenter))
                title.position(x: geo.size.width / 2, y: geo.size.height * Self.treeCenter)
            }
            .ignoresSafeArea()
            VStack {
                Spacer(minLength: 0)
                menu.padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .overlay(alignment: .top) { topBar }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showLibrary) { LibraryView() }
        .sheet(isPresented: $showHelp) { HelpView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $showGames) { GamesView(start: LaunchOptions.game) }
        .onAppear { withAnimation(.spring(duration: 0.8).delay(0.2)) { appeared = true } }
    }

    /// Where the tree's trunk crosses the title, as a fraction of the height (as on the icon).
    static let treeCenter: CGFloat = 0.29

    private var title: some View {
        VStack(spacing: 6) {
            Text("Etymon")
                .font(.system(size: 56, weight: .regular, design: .serif))
                .foregroundStyle(.white)
                .shadow(color: IconPalette.gold.opacity(0.55), radius: 18)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            Text("The roots behind the words around you")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .shadow(color: IconPalette.navy, radius: 4)
        }
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.94)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                .accessibilityLabel("Help").accessibilityIdentifier("homeHelp")
            Button { showSettings = true } label: { Image(systemName: "gear") }
                .accessibilityLabel("Settings").accessibilityIdentifier("homeSettings")
        }
        .font(.title3)
        .foregroundStyle(.white.opacity(0.85))
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .environment(\.colorScheme, .dark)
    }

    private var menu: some View {
        VStack(spacing: 10) {
            ForEach(Array(ContentView.Source.available.enumerated()), id: \.element) { i, source in
                ModeCard(symbol: source.symbol, title: source.title, text: source.blurb,
                         color: source.color) { onOpen(source) }
                    .accessibilityIdentifier("home-\(source.rawValue)")
                    .modifier(Arrive(shown: appeared, index: i))
            }
            ModeCard(symbol: "gamecontroller", title: "Games",
                     text: "Root Chain, Impostor, Cousin Hunt, Birthplace, Scavenger: play with the roots.",
                     color: IconPalette.blue) { showGames = true }
                .accessibilityIdentifier("homeGames")
                .modifier(Arrive(shown: appeared, index: ContentView.Source.available.count))
            ModeCard(symbol: "books.vertical", title: "My network",
                     text: "Everything you saved, offline: as a list, on a map, as one network.",
                     color: IconPalette.coral) { showLibrary = true }
                .accessibilityIdentifier("homeLibrary")
                .modifier(Arrive(shown: appeared, index: ContentView.Source.available.count + 1))
        }
    }
}

/// Cards rise into place one after the other.
private struct Arrive: ViewModifier {
    let shown: Bool
    let index: Int
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 30)
            .animation(.spring(duration: 0.7).delay(0.25 + Double(index) * 0.07), value: shown)
    }
}

private struct ModeCard: View {
    let symbol: String
    let title: String
    let text: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(color.opacity(0.22))
                    Circle().strokeBorder(color.opacity(0.8), lineWidth: 1.5)
                    Image(systemName: symbol).font(.title3).foregroundStyle(color)
                }
                .frame(width: 46, height: 46)
                .shadow(color: color.opacity(0.7), radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(text).font(.caption).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(LinearGradient(colors: [color.opacity(0.5), .white.opacity(0.08)],
                                             startPoint: .leading, endPoint: .trailing),
                              lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(CardPress())
    }
}

private struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

extension ContentView.Source {
    var title: String {
        switch self {
        case .ar: "AR"
        case .camera: "Camera"
        case .photo: "Photo"
        case .type: "Type"
        case .talk: "Talk"
        }
    }

    var symbol: String {
        switch self {
        case .ar: "arkit"
        case .camera: "camera.viewfinder"
        case .photo: "photo"
        case .type: "keyboard"
        case .talk: "bubble.left.and.text.bubble.right"
        }
    }

    var blurb: String {
        switch self {
        case .ar: "Point at signs, menus, books: their shared roots float in the room."
        case .camera: "Point at text: the network is drawn over the video."
        case .photo: "Pick a picture with text and see the network over it."
        case .type: "Type or paste words; see how they connect."
        case .talk: "Listen to a conversation: every word said grows its tree of ancestors."
        }
    }

    var color: Color {
        switch self {
        case .ar, .camera: IconPalette.gold
        case .photo: IconPalette.sky
        case .type: IconPalette.mint
        case .talk: IconPalette.violet
        }
    }
}

/// The app icon's colors: a deep navy field, a warm gold trunk, branches ending in glowing dots.
enum IconPalette {
    static let navy = Color(red: 0.012, green: 0.078, blue: 0.224)
    static let deep = Color(red: 0.05, green: 0.14, blue: 0.36)
    static let gold = Color(red: 1.0, green: 0.83, blue: 0.35)
    static let cream = Color(red: 1.0, green: 0.93, blue: 0.75)
    static let mint = Color(red: 0.36, green: 0.94, blue: 0.71)
    static let violet = Color(red: 0.73, green: 0.55, blue: 1.0)
    static let sky = Color(red: 0.49, green: 0.83, blue: 1.0)
    static let blue = Color(red: 0.35, green: 0.62, blue: 1.0)
    static let coral = Color(red: 1.0, green: 0.48, blue: 0.48)
    static let lavender = Color(red: 0.78, green: 0.76, blue: 1.0)
}

/// The icon's tree, alive: a gold trunk with branches above (ancestors) and roots below,
/// each curving out to a glowing dot. It grows in, then sways; light runs out along the
/// branches; faint motes drift up. Still under Reduce Motion.
struct RootsBackground: View {
    /// The trunk's crossing point, in fractions of the size.
    var center = CGPoint(x: 0.5, y: 0.4)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 30 : timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                draw(in: &context, size: size, t: t)
            }
        }
        .background(
            RadialGradient(colors: [IconPalette.deep, IconPalette.navy],
                           center: UnitPoint(x: center.x, y: center.y),
                           startRadius: 10, endRadius: 600))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    struct Branch {
        /// Where it starts: on the trunk at this height, or partway along another branch.
        let trunk: CGFloat
        let parent: Int?
        let along: CGFloat
        let to: CGPoint  // unit coordinates around the title: x right, y down
        let bend: CGFloat  // how it arrives: 0 straight at the dot, 1 sideways
        let color: Color
        let dot: CGFloat
        let phase: Double
        var far: Bool { parent != nil && along == 1 }
    }

    /// Laid out as on the icon: branches above the title, roots below, a few forks, and a
    /// fainter ring farther out where the network goes on.
    static let branches: [Branch] = {
        func t(_ y: CGFloat, _ x: CGFloat, _ ty: CGFloat, _ bend: CGFloat, _ c: Color, _ d: CGFloat,
               _ p: Double) -> Branch {
            Branch(trunk: y, parent: nil, along: 0, to: CGPoint(x: x, y: ty), bend: bend, color: c, dot: d, phase: p)
        }
        func f(_ parent: Int, _ along: CGFloat, _ x: CGFloat, _ ty: CGFloat, _ bend: CGFloat, _ c: Color,
               _ d: CGFloat, _ p: Double) -> Branch {
            Branch(trunk: 0, parent: parent, along: along, to: CGPoint(x: x, y: ty), bend: bend, color: c,
                   dot: d, phase: p)
        }
        return [
            t(-0.22, -0.72, -0.40, 0.9, IconPalette.violet, 0.045, 0.0),     // 0
            f(0, 0.45, -0.46, -0.74, 0.3, IconPalette.mint, 0.04, 1.1),       // 1
            t(-0.4, 0.0, -0.95, 0.0, IconPalette.gold, 0.06, 2.0),           // 2
            t(-0.24, 0.2, -0.62, 0.15, IconPalette.violet, 0.03, 2.7),       // 3
            t(-0.2, 0.6, -0.64, 0.45, IconPalette.sky, 0.055, 3.6),          // 4
            f(4, 0.5, 0.72, -0.3, 0.8, IconPalette.mint, 0.035, 4.4),        // 5
            t(0.2, -0.74, 0.34, 0.9, IconPalette.mint, 0.04, 0.6),           // 6
            f(6, 0.5, -0.54, 0.62, 0.35, IconPalette.violet, 0.04, 1.5),     // 7
            t(0.22, -0.24, 0.8, 0.15, IconPalette.sky, 0.05, 2.3),           // 8
            t(0.24, 0.09, 0.66, 0.05, IconPalette.sky, 0.035, 3.1),          // 9
            t(0.2, 0.42, 0.58, 0.35, IconPalette.coral, 0.045, 3.9),         // 10
            f(10, 0.5, 0.76, 0.34, 0.9, IconPalette.lavender, 0.04, 4.8),    // 11
            f(0, 1, -1.0, -0.64, 0.5, IconPalette.blue, 0.025, 5.2),
            f(4, 1, 0.94, -0.88, 0.4, IconPalette.lavender, 0.025, 5.9),
            f(7, 1, -0.9, 0.94, 0.4, IconPalette.mint, 0.025, 0.3),
            f(10, 1, 0.68, 1.0, 0.3, IconPalette.violet, 0.025, 1.9),
        ]
    }()

    /// Motes drifting up: x, start y, speed, size, color.
    static let motes: [(x: CGFloat, y: CGFloat, speed: CGFloat, size: CGFloat, color: Color)] = {
        var rng = SeededRandom(seed: 7)
        let colors = [IconPalette.gold, IconPalette.mint, IconPalette.violet, IconPalette.sky,
                      IconPalette.coral, IconPalette.lavender]
        return (0..<44).map { i in
            (rng.next(), rng.next(), 0.006 + rng.next() * 0.018, 0.8 + rng.next() * 1.8,
             colors[i % colors.count])
        }
    }()

    private func draw(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let scale = min(size.width * 0.44, size.height * 0.2)
        let origin = CGPoint(x: size.width * center.x, y: size.height * center.y)
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }

        // motes
        for m in Self.motes {
            let y = (m.y - CGFloat(t) * m.speed).truncatingRemainder(dividingBy: 1)
            let p = CGPoint(x: m.x * size.width + sin(t * 0.3 + Double(m.y) * 9) * 8,
                            y: (y < 0 ? y + 1 : y) * size.height)
            let twinkle = 0.25 + 0.2 * sin(t * 1.3 + Double(m.x) * 20)
            context.fill(Path(ellipseIn: CGRect(x: p.x - m.size, y: p.y - m.size,
                                                width: m.size * 2, height: m.size * 2)),
                         with: .color(m.color.opacity(twinkle)))
        }

        // warm glow where the trunk meets the title
        let breathe = 1 + 0.06 * sin(t * 0.8)
        let glow = scale * 0.55 * breathe
        context.fill(Path(ellipseIn: CGRect(x: origin.x - glow, y: origin.y - glow * 0.8,
                                            width: glow * 2, height: glow * 1.6)),
                     with: .radialGradient(Gradient(colors: [IconPalette.gold.opacity(0.22), .clear]),
                                           center: origin, startRadius: 0, endRadius: glow))

        let grow = { (delay: Double) -> CGFloat in
            let x = min(max((t - delay) / 1.6, 0), 1)
            return CGFloat(1 - pow(1 - x, 3))
        }
        var trunk = Path()
        trunk.move(to: at(CGPoint(x: 0, y: 0.62)))
        trunk.addCurve(to: at(CGPoint(x: 0, y: -0.5)),
                       control1: at(CGPoint(x: 0.02 * sin(t * 0.4), y: 0.2)),
                       control2: at(CGPoint(x: -0.02 * sin(t * 0.4), y: -0.2)))
        stroke(trunk.trimmedPath(from: 0.5 - grow(0) / 2, to: 0.5 + grow(0) / 2), in: &context,
               from: at(CGPoint(x: 0, y: -0.5)), to: at(CGPoint(x: 0, y: 0.62)),
               colors: [IconPalette.gold, IconPalette.cream, IconPalette.gold], width: 3.2, scale: scale)

        // branches, tips moving; forks start on their branch wherever it is now
        var curves: [[CGPoint]] = []  // unit coordinates: from, c1, c2, to
        for (i, b) in Self.branches.enumerated() {
            let sway = CGPoint(x: 0.025 * sin(t * 0.5 + b.phase), y: 0.02 * cos(t * 0.37 + b.phase * 1.3))
            let to = CGPoint(x: b.to.x + sway.x, y: b.to.y + sway.y)
            let from: CGPoint
            if let parent = b.parent {
                let c = curves[parent]
                from = bezier(c[0], c[1], c[2], c[3], b.along)
            } else {
                from = CGPoint(x: 0, y: b.trunk)
            }
            let c1 = CGPoint(x: from.x + (to.x - from.x) * 0.1, y: from.y + (to.y - from.y) * 0.5)
            let c2 = CGPoint(x: to.x + (from.x - to.x) * b.bend * 0.6,
                             y: to.y + (from.y - to.y) * (1 - b.bend) * 0.4)
            curves.append([from, c1, c2, to])
            var path = Path()
            path.move(to: at(from))
            path.addCurve(to: at(to), control1: at(c1), control2: at(c2))
            let far = b.far
            let g = grow(0.5 + Double(i) * 0.07 + (far ? 0.5 : 0))
            stroke(path.trimmedPath(from: 0, to: g), in: &context, from: at(from), to: at(to),
                   colors: [IconPalette.gold.opacity(far ? 0.5 : 1), b.color.opacity(far ? 0.5 : 1)],
                   width: far ? 1.6 : 2.4, scale: scale)

            // light running out along the branch, toward the dot
            let u = (t * 0.18 + b.phase / 6).truncatingRemainder(dividingBy: 1.6)
            if g >= 1, u < 1 {
                let p = at(bezier(from, c1, c2, to, CGFloat(u)))
                let r = 2.6 * sin(.pi * u)
                context.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                             with: .radialGradient(Gradient(colors: [b.color.opacity(0.7), .clear]),
                                                   center: p, startRadius: 0, endRadius: r * 3))
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(0.85)))
            }

            // the dot
            let pop = min(max((g - 0.85) / 0.15, 0), 1)
            let r = b.dot * scale * 0.5 * pop * (1 + 0.12 * sin(t * 1.4 + b.phase))
            guard r > 0 else { continue }
            let p = at(to)
            context.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                         with: .radialGradient(Gradient(colors: [b.color.opacity(far ? 0.3 : 0.55), .clear]),
                                               center: p, startRadius: r * 0.5, endRadius: r * 3))
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(colors: [.white, b.color]),
                                               center: CGPoint(x: p.x - r * 0.3, y: p.y - r * 0.3),
                                               startRadius: 0, endRadius: r * 1.3))
        }
    }

    /// A glowing line: a wide faint stroke, a narrower one, and the line itself.
    private func stroke(_ path: Path, in context: inout GraphicsContext, from: CGPoint, to: CGPoint,
                        colors: [Color], width: CGFloat, scale: CGFloat) {
        let shading = GraphicsContext.Shading.linearGradient(Gradient(colors: colors), startPoint: from, endPoint: to)
        for (w, o) in [(width * 5, 0.08), (width * 2.4, 0.18), (width, 1.0)] {
            var layer = context
            layer.opacity = o
            layer.stroke(path, with: shading, style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
    }

    private func bezier(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ u: CGFloat) -> CGPoint {
        let v = 1 - u
        let x = v * v * v * a.x + 3 * v * v * u * b.x + 3 * v * u * u * c.x + u * u * u * d.x
        let y = v * v * v * a.y + 3 * v * v * u * b.y + 3 * v * u * u * c.y + u * u * u * d.y
        return CGPoint(x: x, y: y)
    }
}

/// Same motes every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
}
