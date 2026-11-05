import SwiftUI

/// The network drawn over the picture or the live video, anchored to the words where
/// they are: each word outlined in place, shared ancestors floating above the words
/// they join (solid curves), translations joined by dashed arcs ("= open"). As tracking
/// moves the words, everything follows.
struct OverlayView: View {
    let response: SceneResponse
    let model: SceneModel
    /// How the image is shown underneath: aspect-fill (video preview) or aspect-fit (photo).
    let fill: Bool
    var onSelect: (GraphLayout.Key) -> Void

    var body: some View {
        GeometryReader { geo in
            // redraw a few times a second so words that left the frame fade out
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                let scene = OverlayScene(response: response, model: model, fill: fill,
                                         size: geo.size, now: timeline.date)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in scene.draw(in: &context) }
                        .allowsHitTesting(false)

                    // tap targets on the words themselves
                    ForEach(scene.wordRects.keys.sorted(), id: \.self) { i in
                        let rect = scene.wordRects[i]!
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: rect.width + 8, height: rect.height + 8)
                            .position(x: rect.midX, y: rect.midY)
                            .onTapGesture { onSelect(.word(i)) }
                            .accessibilityElement()
                            .accessibilityLabel(response.words[i].text)
                            .accessibilityIdentifier("word-\(response.words[i].key)")
                            .accessibilityAddTraits(.isButton)
                    }

                    ForEach(scene.bubbles) { bubble in
                        AncestorBubble(node: response.node(bubble.node), meaning: bubble.meaning)
                            .position(bubble.center)
                            .onTapGesture { onSelect(.term(bubble.node)) }
                    }
                    ForEach(scene.meaningLabels, id: \.id) { label in
                        Text("= \(label.meaning)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.85)))
                            .foregroundStyle(.white)
                            .position(label.center)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.linear(duration: 0.12), value: scene.signature)
            }
        }
    }
}

/// Positions for one frame of the overlay, in view coordinates.
struct OverlayScene {
    struct Bubble: Identifiable {
        let node: Int
        var center: CGPoint
        let words: [Int]
        let meaning: String?  // the joined words also mean the same: "= night"
        let height: CGFloat
        var id: Int { node }
    }

    struct MeaningLabel {
        let id: String
        let meaning: String
        let center: CGPoint
        let a: CGRect
        let b: CGRect
        let arcDepth: CGFloat
    }

    private(set) var wordRects: [Int: CGRect] = [:]
    private(set) var bubbles: [Bubble] = []
    private(set) var meaningLabels: [MeaningLabel] = []
    private(set) var signature: [CGFloat] = []  // drives the position animation
    private let connected: Set<Int>

    static let bubbleSize = CGSize(width: 120, height: 40)

    @MainActor
    init(response: SceneResponse, model: SceneModel, fill: Bool, size: CGSize, now: Date) {
        // where each visible scene word is on screen
        for (i, word) in response.words.enumerated() {
            guard model.isVisible(word.key, at: now), let box = model.boxes[word.key] else { continue }
            wordRects[i] = Self.viewRect(box, imageSize: model.imageSize, in: size, fill: fill)
        }

        // one bubble per shared ancestor, above the words it joins, placed where it covers
        // no word; if the words it joins also mean the same, the meaning goes in the bubble
        var byMeet: [Int: Set<Int>] = [:]
        for c in response.connections where wordRects[c.a] != nil && wordRects[c.b] != nil {
            byMeet[c.meet, default: []].formUnion([c.a, c.b])
        }
        connected = Set(byMeet.values.joined())
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        var occupied = wordRects.values.map { $0.insetBy(dx: -6, dy: -4) }
        let bubble = Self.bubbleSize
        var shownMeanings = Set<String>()
        for (meet, words) in byMeet.sorted(by: { $0.key < $1.key }) {
            let rects = words.compactMap { wordRects[$0] }
            let x = rects.map(\.midX).reduce(0, +) / CGFloat(rects.count)
            let top = rects.map(\.minY).min() ?? 0
            let meaning = response.semanticLinks.first { words.contains($0.a) && words.contains($0.b) }
            if let meaning { shownMeanings.insert(meaning.id) }
            let height = bubble.height + (meaning == nil ? 0 : 14)
            let center = Self.place(CGSize(width: bubble.width, height: height),
                                    near: CGPoint(x: x, y: top - height / 2 - 18),
                                    avoiding: occupied, in: bounds)
            occupied.append(CGRect(x: center.x - bubble.width / 2, y: center.y - height / 2,
                                   width: bubble.width, height: height).insetBy(dx: -4, dy: -4))
            bubbles.append(Bubble(node: meet, center: center, words: words.sorted(),
                                  meaning: meaning?.meaning, height: height))
        }

        // translations not already shown in a bubble: an arc below the two words, its
        // label placed off the text
        for link in response.semanticLinks where !shownMeanings.contains(link.id) {
            guard let a = wordRects[link.a], let b = wordRects[link.b] else { continue }
            let labelSize = CGSize(width: CGFloat(link.meaning.count) * 7 + 28, height: 20)
            let center = Self.place(labelSize,
                                    near: CGPoint(x: (a.midX + b.midX) / 2, y: max(a.maxY, b.maxY) + 22),
                                    avoiding: occupied, in: bounds, downFirst: true)
            occupied.append(CGRect(x: center.x - labelSize.width / 2, y: center.y - labelSize.height / 2,
                                   width: labelSize.width, height: labelSize.height))
            meaningLabels.append(MeaningLabel(id: link.id, meaning: link.meaning, center: center,
                                              a: a, b: b, arcDepth: 0))
        }

        signature = wordRects.sorted { $0.key < $1.key }.flatMap { [$0.value.midX, $0.value.midY] }
            + bubbles.flatMap { [$0.center.x, $0.center.y] }
    }

    /// The free spot nearest to `preferred` for a box of `size`: tries stepping up (or down
    /// first), then sideways, clamped to the view; falls back to the preferred spot.
    static func place(_ size: CGSize, near preferred: CGPoint, avoiding occupied: [CGRect],
                      in bounds: CGRect, downFirst: Bool = false) -> CGPoint {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX + size.width / 2), bounds.maxX - size.width / 2),
                    y: min(max(p.y, bounds.minY + size.height / 2), bounds.maxY - size.height / 2))
        }
        func free(_ p: CGPoint) -> Bool {
            let r = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                           width: size.width, height: size.height)
            return !occupied.contains { $0.intersects(r) }
        }
        let step = size.height + 6
        var vertical: [CGFloat] = [0]
        for k in 1...8 {
            vertical += downFirst ? [CGFloat(k) * step, -CGFloat(k) * step]
                                  : [-CGFloat(k) * step, CGFloat(k) * step]
        }
        for dx in [0, -size.width * 0.6, size.width * 0.6] {
            for dy in vertical {
                let p = clamp(CGPoint(x: preferred.x + dx, y: preferred.y + dy))
                if free(p) { return p }
            }
        }
        return clamp(preferred)
    }

    /// Maps a normalized, top-left-origin box in the upright image onto the view, matching
    /// how the image is scaled: aspect-fill for the video preview, aspect-fit for photos.
    static func viewRect(_ box: CGRect, imageSize: CGSize, in view: CGSize, fill: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let sx = view.width / imageSize.width, sy = view.height / imageSize.height
        let scale = fill ? max(sx, sy) : min(sx, sy)
        let w = imageSize.width * scale, h = imageSize.height * scale
        let ox = (view.width - w) / 2, oy = (view.height - h) / 2
        return CGRect(x: ox + box.minX * w, y: oy + box.minY * h,
                      width: box.width * w, height: box.height * h)
    }

    func draw(in context: inout GraphicsContext) {
        // word outlines: connected words highlighted
        for (i, rect) in wordRects {
            let shape = Path(roundedRect: rect.insetBy(dx: -4, dy: -3), cornerRadius: 6)
            let isLinked = connected.contains(i) || meaningLabels.contains { $0.a == rect || $0.b == rect }
            context.fill(shape, with: .color(.black.opacity(isLinked ? 0.18 : 0.08)))
            context.stroke(shape, with: .color(isLinked ? .yellow : .white.opacity(0.6)),
                           lineWidth: isLinked ? 2.5 : 1)
        }
        // descent: curves from each word up to its shared ancestor
        for bubble in bubbles {
            for i in bubble.words {
                guard let rect = wordRects[i] else { continue }
                let from = CGPoint(x: rect.midX, y: rect.minY - 3)
                let to = CGPoint(x: bubble.center.x, y: bubble.center.y + bubble.height / 2)
                var path = Path()
                path.move(to: from)
                path.addCurve(to: to, control1: CGPoint(x: from.x, y: (from.y + to.y) / 2),
                              control2: CGPoint(x: to.x, y: (from.y + to.y) / 2))
                context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 5)
                context.stroke(path, with: .color(.yellow), lineWidth: 2.5)
            }
        }
        // meaning: dashed arcs under the two words
        for label in meaningLabels {
            let from = CGPoint(x: label.a.midX, y: label.a.maxY + 3)
            let to = CGPoint(x: label.b.midX, y: label.b.maxY + 3)
            var path = Path()
            path.move(to: from)
            path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2,
                                                       y: max(from.y, to.y) + 28))
            context.stroke(path, with: .color(.black.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 5, dash: [7, 5]))
            context.stroke(path, with: .color(.green),
                           style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
        }
    }
}

private struct AncestorBubble: View {
    let node: Node?
    let meaning: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(node?.word ?? "?")
                .font(.subheadline.bold()).italic(node?.reconstructed ?? false)
            Text(node?.language ?? "")
                .font(.system(size: 9)).foregroundStyle(Color.black.opacity(0.6))
            if let meaning {
                Text("= \(meaning)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.0, green: 0.5, blue: 0.2))  // readable on yellow
            }
        }
        .lineLimit(1)
        .frame(maxWidth: OverlayScene.bubbleSize.width)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 1.0, green: 0.92, blue: 0.62)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .foregroundStyle(.black)
    }
}
