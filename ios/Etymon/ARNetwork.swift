import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UIKit
import simd

/// Where a word read by the camera is in the room, in ARKit world coordinates (metres,
/// y up), how far it was from the camera when found (labels are sized to stay readable
/// from there), and when it was last read.
struct ARWordAnchor: Equatable {
    var position: SIMD3<Float>
    var distance: Float
    var seen: Date
    /// Timestamp of the camera frame the position comes from: a slower read of an older
    /// frame must not pull the word back to where it was.
    var frame: TimeInterval = 0
    var reads = 1

    /// Re-read within a hair of where it was (the jitter of reading and of finding the
    /// surface): the running mean of the reads so far, so a still word stays still.
    /// Re-read anywhere else: the word moved (a book picked up, a box slid) or it is
    /// another copy of it; the tag goes there at once.
    mutating func update(to p: SIMD3<Float>, distance d: Float, at now: Date, frame: TimeInterval = 0) {
        if simd_distance(p, position) < Self.jitter(at: distance) {
            let w = 1 / Float(min(reads, Self.maxWeight) + 1)
            position += (p - position) * w
            distance += (d - distance) * w
            reads += 1
        } else {
            position = p
            distance = d
            reads = 1
        }
        seen = now
        self.frame = max(self.frame, frame)
    }

    static let maxWeight = 3
    /// How far reads of a still word scatter: about 1.5 cm at 1 m, more further away.
    static func jitter(at distance: Float) -> Float { max(0.012, 0.015 * distance) }
}

/// Image and camera geometry for turning a word read in a frame into a point in space.
enum ARGeometry {
    /// A point in the upright portrait image (normalized, top-left origin, as Recognition
    /// gives it) in the camera's own landscape image, the one ARKit's intrinsics describe.
    /// Upright = the sensor image turned a quarter clockwise (orientation `.right`).
    /// `orientation` is how the upright image sits on the sensor's, as passed to Vision;
    /// portrait (`.right`) by default.
    static func sensorPoint(upright p: CGPoint, orientation: CGImagePropertyOrientation = .right) -> CGPoint {
        switch orientation {
        case .up: return p  // landscape, home button (or USB-C) on the right: the sensor's own
        case .down: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .left: return CGPoint(x: 1 - p.y, y: p.x)  // portrait upside down
        default: return CGPoint(x: p.y, y: 1 - p.x)  // portrait
        }
    }

    /// How the phone is held, for reading text upright and turning labels to match.
    /// Face up or down, or unknown: nil (keep the last one).
    static func imageOrientation(for device: UIDeviceOrientation) -> CGImagePropertyOrientation? {
        switch device {
        case .portrait: return .right
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        default: return nil
        }
    }

    /// The roll that keeps a camera-facing label upright for the person holding the phone:
    /// counter to the phone's turn. Positive is anticlockwise as seen on screen.
    static func labelRoll(for orientation: CGImagePropertyOrientation) -> Float {
        switch orientation {
        case .up: return -.pi / 2  // phone turned anticlockwise: labels turn back clockwise
        case .down: return .pi / 2
        case .left: return .pi
        default: return 0
        }
    }

    /// Size of the upright image: portrait swaps the sensor's width and height.
    static func uprightSize(_ resolution: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        orientation == .up || orientation == .down
            ? resolution : CGSize(width: resolution.height, height: resolution.width)
    }

    /// The ray from the camera through a point of its image (normalized, top-left origin),
    /// in world coordinates. ARKit's camera looks down -z with y up; image y runs down.
    static func ray(through p: CGPoint, intrinsics k: simd_float3x3, resolution: CGSize,
                    cameraTransform t: simd_float4x4) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let px = Float(p.x * resolution.width), py = Float(p.y * resolution.height)
        let fx = k.columns.0.x, fy = k.columns.1.y, cx = k.columns.2.x, cy = k.columns.2.y
        let local = simd_normalize(SIMD3((px - cx) / fx, -(py - cy) / fy, -1))
        let world = t * SIMD4(local, 0)
        let origin = t.columns.3
        return (SIMD3(origin.x, origin.y, origin.z), simd_normalize(SIMD3(world.x, world.y, world.z)))
    }

    /// Whether the camera moved faster than a steady hand between two frames: more than
    /// 25 cm/s, or turning faster than about 30°/s.
    static func isMoving(from a: simd_float4x4, to b: simd_float4x4, seconds: TimeInterval) -> Bool {
        guard seconds > 0 else { return false }
        let ta = SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let tb = SIMD3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        let speed = simd_distance(ta, tb) / Float(seconds)
        let turn = (simd_quatf(b) * simd_quatf(a).inverse).angle
        let angle = min(turn, 2 * .pi - turn)  // the shorter way round
        return speed > 0.25 || angle / Float(seconds) > 0.5
    }

    /// A copy of a camera image (any planar layout), so the original can go back to the
    /// session straight away.
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                            CVPixelBufferGetPixelFormatType(source), attributes, &made)
        guard let copy = made else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planar = CVPixelBufferIsPlanar(source)
        for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(source) : 1) {
            let from = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
            let to = planar ? CVPixelBufferGetBaseAddressOfPlane(copy, plane) : CVPixelBufferGetBaseAddress(copy)
            guard let from, let to else { return nil }
            let rows = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
            let fromRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let toRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(copy, plane) : CVPixelBufferGetBytesPerRow(copy)
            if fromRow == toRow {
                memcpy(to, from, rows * fromRow)
            } else {
                for r in 0..<rows { memcpy(to + r * toRow, from + r * fromRow, min(fromRow, toRow)) }
            }
        }
        return copy
    }
}

/// The scene's network placed in the room: each word where it was read, each shared root
/// floating above the words it joins, same-meaning pairs joined by arcs below them.
/// Distances scale with how far away the words are, so a sign across the street gets a
/// network as readable as a label on the table.
struct ARNetworkLayout {
    struct Word {
        let index: Int
        let key: String
        let position: SIMD3<Float>
        let scale: Float  // distance from the camera when read, metres
        let linked: Bool
    }

    struct Root {
        let node: Int
        let position: SIMD3<Float>
        let words: [Int]
        let meaning: String?  // the joined words also mean the same: "= night"
        let scale: Float
    }

    struct Arc {
        let id: String
        let a: Int
        let b: Int
        let meaning: String
    }

    private(set) var words: [Int: Word] = [:]
    private(set) var roots: [Root] = []

    private(set) var arcs: [Arc] = []

    /// What is shown and where, to the millimetre: equal signatures draw the same picture,
    /// so the view can skip redrawing.
    var signature: String {
        func mm(_ p: SIMD3<Float>) -> String {
            "\(Int((p.x * 1000).rounded())),\(Int((p.y * 1000).rounded())),\(Int((p.z * 1000).rounded()))"
        }
        let w = words.values.sorted { $0.index < $1.index }
            .map { "\($0.index):\($0.key):\($0.linked):\(mm($0.position)):\(Int($0.scale * 100))" }
        let r = roots.map { "\($0.node):\($0.words):\($0.meaning ?? ""):\(mm($0.position))" }
        return (w + ["|"] + r + ["|"] + arcs.map(\.id)).joined(separator: ";")
    }

    init(response: SceneResponse, anchors: [String: ARWordAnchor]) {
        var located: [Int: ARWordAnchor] = [:]
        for (i, word) in response.words.enumerated() {
            if let anchor = anchors[word.key] { located[i] = anchor }
        }

        var byMeet: [Int: Set<Int>] = [:]
        for c in response.connections where located[c.a] != nil && located[c.b] != nil {
            byMeet[c.meet, default: []].formUnion([c.a, c.b])
        }

        var shownMeanings = Set<String>()
        for (meet, members) in byMeet.sorted(by: { $0.key < $1.key }) {
            let anchors = members.sorted().compactMap { located[$0] }
            let n = Float(anchors.count)
            let center = anchors.map(\.position).reduce(.zero, +) / n
            let scale = anchors.map(\.distance).reduce(0, +) / n
            let spread = anchors.map { simd_length(SIMD2($0.position.x - center.x, $0.position.z - center.z)) }
                .max() ?? 0
            var position = center + SIMD3(0, max(0.15 * scale, 0.6 * spread), 0)
            // roots over the same words stack up instead of overlapping
            while roots.contains(where: { simd_distance($0.position, position) < 0.12 * scale }) {
                position.y += 0.1 * scale
            }
            let meaning = response.semanticLinks.first { members.contains($0.a) && members.contains($0.b) }
            if let meaning { shownMeanings.insert(meaning.id) }
            roots.append(Root(node: meet, position: position, words: members.sorted(),
                              meaning: meaning?.meaning, scale: scale))
        }

        for link in response.semanticLinks where !shownMeanings.contains(link.id) {
            guard located[link.a] != nil, located[link.b] != nil else { continue }
            arcs.append(Arc(id: link.id, a: link.a, b: link.b, meaning: link.meaning))
        }

        let linked = Set(byMeet.values.joined()).union(arcs.flatMap { [$0.a, $0.b] })
        for (i, anchor) in located {
            words[i] = Word(index: i, key: response.words[i].key, position: anchor.position,
                            scale: anchor.distance, linked: linked.contains(i))
        }
    }
}

/// One branch of the network picked out in AR: a shared root (with everything between it
/// and its words) or a same-meaning pair. Everything else is hidden until it is let go.
enum ARFocus: Equatable, Hashable {
    case root(Int)  // the meeting node's id
    case meaning(String)  // ARNetworkLayout.Arc id
}

/// A shared root's branch laid out in the room for exploring: each word's full path up to
/// the root, every ancestor in between on its own card along the way, and the root's own
/// older ancestry stacked above it. Ancestors two words share are drawn once, so the
/// paths merge where the words' histories meet.
struct ARBranchLayout {
    struct Card {
        let node: Int
        let position: SIMD3<Float>
        let scale: Float
    }

    struct Segment: Hashable {
        let id: String
        let from: SIMD3<Float>
        let to: SIMD3<Float>
        let kind: String?  // the edge: inherited, borrowed…
        let scale: Float
    }

    let meet: Int
    let words: [Int]
    /// The root, raised so the longest path has room for its cards.
    let rootPosition: SIMD3<Float>
    let scale: Float
    private(set) var cards: [Card] = []
    private(set) var segments: [Segment] = []

    /// Room between two cards along a path, and between ancestors above the root, at 1 m.
    static let step: Float = 0.08
    /// Half a card's height at 1 m: lines end at the card's edge, not its middle.
    static let cardHalf: Float = 0.035

    /// `middle`: how many of the steps between each word and the root are drawn, and of
    /// those between the root and the oldest ancestor above it (TreeDepth; `all`: every one).
    /// The ones nearest the word (the root) stay; a faint segment jumps over the rest.
    init?(meet: Int, response: SceneResponse, layout: ARNetworkLayout, middle: Int = TreeDepth.all) {
        guard let root = layout.roots.first(where: { $0.node == meet }) else { return nil }
        self.meet = meet
        let s = root.scale
        scale = s
        let up = SIMD3<Float>(0, 1, 0)

        var paths: [(word: Int, steps: [Step])] = []
        for i in root.words {
            guard let c = response.connections.first(where: { $0.meet == meet && ($0.a == i || $0.b == i) })
            else { continue }
            paths.append((i, c.a == i ? c.pathA : c.pathB))
        }
        words = paths.map(\.word)
        func kept(_ steps: ArraySlice<Step>) -> (shown: [Step], skipped: Int) {
            middle == TreeDepth.all ? (Array(steps), 0) : (Array(steps.prefix(middle)), max(steps.count - middle, 0))
        }
        let longest = paths.map { kept($0.steps.dropFirst().dropLast()).shown.count }.max() ?? 0
        let top = root.position + up * (Self.step * s * Float(longest))
        rootPosition = top

        var placed: [Int: SIMD3<Float>] = [meet: top]
        var seen = Set<String>()
        func link(_ id: String, _ from: SIMD3<Float>, _ to: SIMD3<Float>, _ kind: String?) {
            guard seen.insert(id).inserted else { return }
            segments.append(Segment(id: id, from: from, to: to, kind: kind, scale: s))
        }
        for (i, steps) in paths {
            guard let word = layout.words[i] else { continue }
            // steps run from the word's own term up to the root; in between, the ancestors
            let (between, skipped) = kept(steps.dropFirst().dropLast())
            var previous = (key: "w\(i)", position: word.position, isCard: false)
            for (k, step) in between.enumerated() where step.node != meet {
                let position: SIMD3<Float>
                if let p = placed[step.node] {
                    position = p
                } else {
                    let t = Float(k + 1) / Float(between.count + 1)
                    position = word.position + (top - word.position) * t
                    placed[step.node] = position
                    cards.append(Card(node: step.node, position: position, scale: s))
                }
                link("\(previous.key)>\(step.node)",
                     previous.position + (previous.isCard ? up * Self.cardHalf * s : .zero),
                     position - up * Self.cardHalf * s, step.kind)
                previous = ("\(step.node)", position, true)
            }
            link("\(previous.key)>\(meet)",
                 previous.position + (previous.isCard ? up * Self.cardHalf * s : .zero),
                 top - up * Self.cardHalf * s, skipped > 0 ? "skip" : steps.count > 1 ? steps.last?.kind : nil)
        }

        // the root's own ancestry, older and higher
        var below = (key: "\(meet)", position: top)
        // the oldest ancestor always shows; the steps up to it are thinned like the paths
        let deeper = response.connections.first { $0.meet == meet }?.deeper.mainLine(above: meet) ?? []
        var above = deeper
        var jump = 0
        if let oldest = deeper.last, middle != TreeDepth.all {
            let (shown, skipped) = kept(deeper.dropLast()[...])
            above = shown + [oldest]
            jump = skipped
        }
        for (k, step) in above.enumerated() where placed[step.node] == nil {
            let position = below.position + up * (Self.step * 1.25 * s)
            placed[step.node] = position
            cards.append(Card(node: step.node, position: position, scale: s))
            let skip = jump > 0 && k == above.count - 1
            link("\(below.key)>\(step.node)", below.position + up * Self.cardHalf * s,
                 position - up * Self.cardHalf * s, skip ? "skip" : step.kind)
            below = ("\(step.node)", position)
        }
    }
}

extension ARGeometry {
    /// Distance on screen from a tap to a line between two projected points.
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        let t = length2 == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
