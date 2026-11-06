import ARKit
import Vision

/// Where a voice comes from: a person in view (their face), a device in view (a TV, a
/// laptop, a phone, a speaker), or somewhere the camera can't see.
enum SpeakerSource: Equatable, Hashable {
    case face(Int)
    case device(Int)
    case somewhere
}

/// A face followed from frame to frame, with how far its mouth was open over time.
struct FaceTrack {
    let id: Int
    var box: CGRect  // upright image, normalized, top-left origin
    var position: SIMD3<Float>  // the head, in the room
    var distance: Float
    var lastSeen: TimeInterval  // frame timestamp
    var mouth: [(time: TimeInterval, open: Float)] = []
}

/// A screen or loudspeaker seen in the room.
struct DeviceSighting {
    let id: Int
    var kind: String  // Vision's label: television, laptop, phone…
    var position: SIMD3<Float>
    var distance: Float
    var lastSeen: TimeInterval
}

/// Talking moves the mouth: open, closed, open again several times a second. A face
/// that is still, or smiling, or chewing slowly barely changes. The score is how much the
/// mouth opening varied (its standard deviation) while someone was talking.
enum MouthActivity {
    /// Above this, the mouth was moving like speech (opening as a fraction of face height).
    static let talking: Float = 0.012
    /// A little before and after: the audio cut and the camera frames don't line up exactly.
    static let margin: TimeInterval = 0.2

    static func score(_ samples: [(time: TimeInterval, open: Float)],
                      from start: TimeInterval, to end: TimeInterval) -> Float? {
        let inside = samples.filter { $0.time >= start - margin && $0.time <= end + margin }.map(\.open)
        // watched for at least a good part of the utterance (faces are read ~10 times a second)
        guard inside.count >= max(3, Int((end - start) * 3)) else { return nil }
        let mean = inside.reduce(0, +) / Float(inside.count)
        let variance = inside.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(inside.count)
        return variance.squareRoot()
    }
}

/// Follows faces across frames: a face is the same one as in the last frame if it is
/// close to where that one was.
struct FaceTracker {
    private(set) var tracks: [FaceTrack] = []
    private var nextID = 1
    /// How far (normalized image units) a face may move between two reads and stay itself.
    static let reach: CGFloat = 0.2
    /// Mouth history kept, seconds: longer than any utterance the backend sends.
    static let history: TimeInterval = 20
    /// A face not seen for this long has gone.
    static let forget: TimeInterval = 4

    struct Face {
        let box: CGRect
        let open: Float?
        let position: SIMD3<Float>
        let distance: Float
    }

    mutating func update(_ faces: [Face], at time: TimeInterval) {
        var free = Set(tracks.indices)
        for face in faces {
            let center = CGPoint(x: face.box.midX, y: face.box.midY)
            let nearest = free.min { a, b in
                Self.gap(tracks[a].box, center) < Self.gap(tracks[b].box, center)
            }
            let index: Int
            if let nearest, Self.gap(tracks[nearest].box, center) < Self.reach {
                index = nearest
                free.remove(nearest)
            } else {
                tracks.append(FaceTrack(id: nextID, box: face.box, position: face.position,
                                        distance: face.distance, lastSeen: time))
                nextID += 1
                index = tracks.count - 1
            }
            tracks[index].box = face.box
            tracks[index].position = face.position
            tracks[index].distance = face.distance
            tracks[index].lastSeen = time
            if let open = face.open { tracks[index].mouth.append((time, open)) }
            tracks[index].mouth.removeAll { $0.time < time - Self.history }
        }
        tracks.removeAll { time - $0.lastSeen > Self.forget }
    }

    func track(_ id: Int) -> FaceTrack? { tracks.first { $0.id == id } }

    private static func gap(_ box: CGRect, _ p: CGPoint) -> CGFloat {
        hypot(box.midX - p.x, box.midY - p.y)
    }
}

/// Watches the camera for who might be talking: faces and their mouths ~10 times a
/// second, screens and loudspeakers about once a second. Asked about an utterance (its
/// start and end, on the frames' clock), it says where the voice most likely came from.
@MainActor
final class SpeakerLocator {
    private(set) var faces = FaceTracker()
    private(set) var devices: [DeviceSighting] = []
    /// The camera as of the last frame: where "somewhere" voices are placed.
    private(set) var camera: simd_float4x4?
    var onUpdate: () -> Void = {}

    /// Vision's labels for things that talk.
    nonisolated static let deviceKinds: Set<String> = ["television", "computer_monitor", "laptop", "computer",
                                           "phone", "speakers_music"]
    /// A head is about this wide: its size in the image says how far away it is.
    static let faceWidth: Float = 0.15

    private var faceBusy = false, deviceBusy = false
    private var lastFace: TimeInterval = 0, lastDevice: TimeInterval = 0
    private var nextDevice = 1
    private let queue = DispatchQueue(label: "etymon.speakers", qos: .userInitiated)

    func reset() {
        faces = FaceTracker()
        devices = []
    }

    func consider(_ frame: ARFrame, session: ARSession) {
        camera = frame.camera.transform
        let time = frame.timestamp
        let cam = (intrinsics: frame.camera.intrinsics, resolution: frame.camera.imageResolution,
                   transform: frame.camera.transform)
        if !faceBusy, time - lastFace >= 0.09 {
            // a copy: holding one of the session's few camera buffers makes it drop frames
            guard let buffer = ARGeometry.copy(frame.capturedImage) else { return }
            faceBusy = true
            lastFace = time
            queue.async { [weak self] in
                let found = Self.readFaces(buffer)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.faceBusy = false
                    let faces = found.map { f -> FaceTracker.Face in
                        let place = Self.place(f.box, widthInRoom: Self.faceWidth, camera: cam)
                        return .init(box: f.box, open: f.open, position: place.position, distance: place.distance)
                    }
                    self.faces.update(faces, at: time)
                    self.onUpdate()
                }
            }
        } else if !deviceBusy, time - lastDevice >= 1.0 {
            guard let buffer = ARGeometry.copy(frame.capturedImage) else { return }
            deviceBusy = true
            lastDevice = time
            queue.async { [weak self] in
                let found = Self.readDevices(buffer)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.deviceBusy = false
                    for d in found { self.saw(d.kind, box: d.box, camera: cam, session: session, at: time) }
                    self.onUpdate()
                }
            }
        }
    }

    /// Who said what was said between `start` and `end`: the face whose mouth moved most
    /// (if it moved like speech); else a device seen around then; else somewhere unseen.
    func source(from start: TimeInterval, to end: TimeInterval) -> (SpeakerSource, Float) {
        let scored = faces.tracks.compactMap { t in
            MouthActivity.score(t.mouth, from: start, to: end).map { (t.id, $0) }
        }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= MouthActivity.talking {
            return (.face(best.0), best.1)
        }
        let recent = devices.filter { $0.lastSeen >= start - 3 && $0.lastSeen <= end + 2 }
        if let device = recent.max(by: { $0.lastSeen < $1.lastSeen }) {
            return (.device(device.id), scored.map(\.1).max() ?? 0)
        }
        return (.somewhere, scored.map(\.1).max() ?? 0)
    }

    func position(of source: SpeakerSource) -> (position: SIMD3<Float>, distance: Float)? {
        switch source {
        case .face(let id): return faces.track(id).map { ($0.position, $0.distance) }
        case .device(let id): return devices.first { $0.id == id }.map { ($0.position, $0.distance) }
        case .somewhere: return nil
        }
    }

    func device(_ id: Int) -> DeviceSighting? { devices.first { $0.id == id } }

    // MARK: reading frames

    private nonisolated static func readFaces(_ buffer: CVPixelBuffer) -> [(box: CGRect, open: Float?)] {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([request])
        return (request.results ?? []).map { face in
            // Vision: bottom-left origin; the app's boxes: top-left
            let b = face.boundingBox
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            // inner lips, in face-box units: how far apart the top and bottom lips are
            let open = face.landmarks?.innerLips.map { lips -> Float in
                let ys = lips.normalizedPoints.map { Float($0.y) }
                return (ys.max() ?? 0) - (ys.min() ?? 0)
            }
            return (box, open)
        }
    }

    private nonisolated static func readDevices(_ buffer: CVPixelBuffer) -> [(kind: String, box: CGRect)] {
        // rectangles big enough to be a screen, each crop asked what it is
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumSize = 0.08
        rectangles.maximumObservations = 4
        rectangles.minimumConfidence = 0.6
        rectangles.quadratureTolerance = 25
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
        let whole = VNClassifyImageRequest()
        try? handler.perform([rectangles, whole])
        var found: [(String, CGRect)] = []
        for r in rectangles.results ?? [] {
            let classify = VNClassifyImageRequest()
            classify.regionOfInterest = r.boundingBox
            try? handler.perform([classify])
            if let kind = deviceKind(classify.results) {
                let b = r.boundingBox
                found.append((kind, CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)))
            }
        }
        // a speaker or phone without a clear outline: the whole view says so, place it centrally
        if found.isEmpty, let kind = deviceKind(whole.results) {
            found.append((kind, CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)))
        }
        return found
    }

    private nonisolated static func deviceKind(_ results: [VNClassificationObservation]?) -> String? {
        (results ?? []).first { deviceKinds.contains($0.identifier) && $0.confidence > 0.3 }?.identifier
    }

    private func saw(_ kind: String, box: CGRect, camera: Camera, session: ARSession, at time: TimeInterval) {
        let ray = ARGeometry.ray(through: ARGeometry.sensorPoint(upright: CGPoint(x: box.midX, y: box.midY)),
                                 intrinsics: camera.intrinsics, resolution: camera.resolution,
                                 cameraTransform: camera.transform)
        let query = ARRaycastQuery(origin: ray.origin, direction: ray.direction,
                                   allowing: .estimatedPlane, alignment: .any)
        let hit = session.raycast(query).first.map { h -> SIMD3<Float> in
            let c = h.worldTransform.columns.3
            return SIMD3(c.x, c.y, c.z)
        }
        let position = hit ?? ray.origin + ray.direction * 1.5
        let distance = simd_distance(position, ray.origin)
        // the same device again if it is where one was seen before
        if let i = devices.firstIndex(where: { simd_distance($0.position, position) < max(0.4, 0.25 * distance) }) {
            devices[i].position = position
            devices[i].distance = distance
            devices[i].lastSeen = time
            devices[i].kind = kind
        } else {
            devices.append(DeviceSighting(id: nextDevice, kind: kind, position: position,
                                          distance: distance, lastSeen: time))
            nextDevice += 1
        }
    }

    typealias Camera = (intrinsics: simd_float3x3, resolution: CGSize, transform: simd_float4x4)

    /// Where something seen in the image is in the room, from how big it looks: an object
    /// `widthInRoom` metres wide, filling `box.width` of the upright image.
    nonisolated static func place(_ box: CGRect, widthInRoom: Float,
                                  camera: Camera) -> (position: SIMD3<Float>, distance: Float) {
        // upright x runs along the sensor's y axis
        let pixels = Float(box.width * camera.resolution.height)
        let focal = camera.intrinsics.columns.1.y
        let distance = min(max(widthInRoom * focal / max(pixels, 1), 0.3), 8)
        let ray = ARGeometry.ray(through: ARGeometry.sensorPoint(upright: CGPoint(x: box.midX, y: box.midY)),
                                 intrinsics: camera.intrinsics, resolution: camera.resolution,
                                 cameraTransform: camera.transform)
        return (ray.origin + ray.direction * distance, distance)
    }
}
