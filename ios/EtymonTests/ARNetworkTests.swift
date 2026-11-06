import XCTest
import simd
@testable import Etymon

final class ARGeometryTests: XCTestCase {
    /// Upright portrait = sensor image turned a quarter clockwise: the upright top-left is
    /// the sensor's bottom-left, the upright top-right the sensor's top-left.
    func testUprightToSensorPoint() {
        XCTAssertEqual(ARGeometry.sensorPoint(upright: CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 1))
        XCTAssertEqual(ARGeometry.sensorPoint(upright: CGPoint(x: 1, y: 0)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(ARGeometry.sensorPoint(upright: CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(ARGeometry.sensorPoint(upright: CGPoint(x: 0.5, y: 0.25)), CGPoint(x: 0.25, y: 0.5))
    }

    /// Each way the phone is held maps the upright image's top-left corner onto the right
    /// corner of the sensor image, and labels turn against the phone.
    func testOrientations() {
        let corner = CGPoint(x: 0, y: 0)
        XCTAssertEqual(ARGeometry.sensorPoint(upright: corner, orientation: .up), CGPoint(x: 0, y: 0))
        XCTAssertEqual(ARGeometry.sensorPoint(upright: corner, orientation: .down), CGPoint(x: 1, y: 1))
        XCTAssertEqual(ARGeometry.sensorPoint(upright: corner, orientation: .left), CGPoint(x: 1, y: 0))
        XCTAssertEqual(ARGeometry.sensorPoint(upright: corner, orientation: .right), CGPoint(x: 0, y: 1))

        XCTAssertEqual(ARGeometry.imageOrientation(for: .portrait), .right)
        XCTAssertEqual(ARGeometry.imageOrientation(for: .landscapeLeft), .up)
        XCTAssertEqual(ARGeometry.imageOrientation(for: .landscapeRight), .down)
        XCTAssertNil(ARGeometry.imageOrientation(for: .faceUp))

        XCTAssertEqual(ARGeometry.labelRoll(for: .right), 0)
        XCTAssertEqual(ARGeometry.labelRoll(for: .up), -.pi / 2)
        XCTAssertEqual(ARGeometry.labelRoll(for: .down), .pi / 2)

        let sensor = CGSize(width: 1920, height: 1440)
        XCTAssertEqual(ARGeometry.uprightSize(sensor, orientation: .right), CGSize(width: 1440, height: 1920))
        XCTAssertEqual(ARGeometry.uprightSize(sensor, orientation: .up), sensor)
    }

    /// Labels ease to the new roll, and take the short way round.
    func testLabelsTurnSmoothlyTheShortWay() {
        UprightLabel.set(roll: 0, now: 0)
        XCTAssertEqual(UprightLabel.roll(at: 10), 0, accuracy: 1e-5)
        UprightLabel.set(roll: .pi / 2, now: 10)
        let half = UprightLabel.roll(at: 10 + UprightLabel.duration / 2)
        XCTAssertGreaterThan(half, 0.1)
        XCTAssertLessThan(half, .pi / 2 - 0.1)
        XCTAssertEqual(UprightLabel.roll(at: 11), .pi / 2, accuracy: 1e-5)
        UprightLabel.set(roll: -.pi / 2 + 2 * .pi, now: 11)  // same as -90°: go down through 0, not up
        XCTAssertEqual(UprightLabel.roll(at: 12), -.pi / 2, accuracy: 1e-5)
        UprightLabel.set(roll: 0, now: 12)
    }

    private let intrinsics = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1)))
    private let resolution = CGSize(width: 1920, height: 1440)

    func testRayThroughImageCentreLooksForward() {
        let ray = ARGeometry.ray(through: CGPoint(x: 0.5, y: 0.5), intrinsics: intrinsics,
                                 resolution: resolution, cameraTransform: matrix_identity_float4x4)
        XCTAssertEqual(ray.origin, .zero)
        XCTAssertEqual(ray.direction.z, -1, accuracy: 1e-5)
    }

    func testRayFollowsImageAxesAndCamera() {
        // right of and above the centre of the sensor image: +x, +y in camera space
        let ray = ARGeometry.ray(through: CGPoint(x: 0.75, y: 0.25), intrinsics: intrinsics,
                                 resolution: resolution, cameraTransform: matrix_identity_float4x4)
        XCTAssertGreaterThan(ray.direction.x, 0)
        XCTAssertGreaterThan(ray.direction.y, 0)
        XCTAssertEqual(simd_length(ray.direction), 1, accuracy: 1e-5)

        // the camera moved 2 m up and turned to face +x
        var t = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 1, 0)))
        t.columns.3 = SIMD4(0, 2, 0, 1)
        let moved = ARGeometry.ray(through: CGPoint(x: 0.5, y: 0.5), intrinsics: intrinsics,
                                   resolution: resolution, cameraTransform: t)
        XCTAssertEqual(moved.origin, SIMD3(0, 2, 0))
        XCTAssertEqual(moved.direction.x, 1, accuracy: 1e-5)
    }

    /// Jitter of a still word averages out; a real move (a book slid 5 cm) is followed
    /// at once; a read of an older frame doesn't pull it back.
    func testAnchorAveragesJitterAndFollowsMoves() {
        let t0 = Date()
        var a = ARWordAnchor(position: SIMD3(0, 0, -1), distance: 1, seen: t0, frame: 1)
        a.update(to: SIMD3(0.006, 0, -1), distance: 1.02, at: t0, frame: 2)
        XCTAssertEqual(a.position.x, 0.003, accuracy: 1e-5)
        XCTAssertEqual(a.distance, 1.01, accuracy: 1e-5)
        a.update(to: SIMD3(0.05, 0, -1), distance: 1, at: t0, frame: 3)
        XCTAssertEqual(a.position, SIMD3(0.05, 0, -1))
        XCTAssertEqual(a.frame, 3)
        a.update(to: SIMD3(3, 0, -1), distance: 4, at: t0, frame: 4)  // the same word on another sign
        XCTAssertEqual(a.position, SIMD3(3, 0, -1))
        XCTAssertEqual(a.distance, 4)
    }

    func testJitterAllowanceGrowsWithDistance() {
        XCTAssertEqual(ARWordAnchor.jitter(at: 0.3), 0.012, accuracy: 1e-6)
        XCTAssertEqual(ARWordAnchor.jitter(at: 3), 0.045, accuracy: 1e-6)
    }

    /// Noisy reads of a still word: the marker settles, each read moving it less.
    func testAnchorSettles() {
        var a = ARWordAnchor(position: SIMD3(0, 0, -1), distance: 1, seen: Date())
        var steps: [Float] = []
        for k in 0..<8 {
            let before = a.position
            a.update(to: SIMD3(k.isMultiple(of: 2) ? 0.006 : -0.006, 0, -1), distance: 1, at: Date())
            steps.append(simd_distance(before, a.position))
        }
        XCTAssertLessThan(steps.last!, steps.first!)
        XCTAssertLessThan(abs(a.position.x), 0.004)
    }

    func testMovingVersusSteady() {
        let still = matrix_identity_float4x4
        var slid = still
        slid.columns.3 = SIMD4(0.01, 0, 0, 1)  // 1 cm in 1/60 s = 60 cm/s
        XCTAssertTrue(ARGeometry.isMoving(from: still, to: slid, seconds: 1.0 / 60))
        XCTAssertFalse(ARGeometry.isMoving(from: still, to: slid, seconds: 1))
        let turned = simd_float4x4(simd_quatf(angle: 0.05, axis: SIMD3(0, 1, 0)))  // 3° per frame
        XCTAssertTrue(ARGeometry.isMoving(from: still, to: turned, seconds: 1.0 / 60))
        XCTAssertFalse(ARGeometry.isMoving(from: still, to: still, seconds: 1.0 / 60))
    }

    func testCopiesBiPlanarCameraImage() throws {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &made)
        let source = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(source, 0), 7, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * 48)
        memset(CVPixelBufferGetBaseAddressOfPlane(source, 1), 9, CVPixelBufferGetBytesPerRowOfPlane(source, 1) * 24)
        CVPixelBufferUnlockBaseAddress(source, [])

        let copy = try XCTUnwrap(ARGeometry.copy(source))
        XCTAssertEqual(CVPixelBufferGetWidth(copy), 64)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(copy), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(copy, 0)!.assumingMemoryBound(to: UInt8.self)
        let c = CVPixelBufferGetBaseAddressOfPlane(copy, 1)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(y[100], 7)
        XCTAssertEqual(c[100], 9)
    }
}

final class ARNetworkLayoutTests: XCTestCase {
    private func response(semantic: [SemanticLink] = []) -> SceneResponse {
        func node(_ id: Int, _ word: String) -> Node {
            Node(id: id, lang: "ine-pro", language: "Proto-Indo-European", word: word, gloss: nil,
                 reconstructed: true, lat: nil, lon: nil)
        }
        let words = [SceneWord(text: "notte", lang: "it", terms: [1], meanings: nil),
                     SceneWord(text: "night", lang: "en", terms: [2], meanings: nil),
                     SceneWord(text: "aperta", lang: "it", terms: [3], meanings: nil)]
        let c1 = Connection(a: 0, b: 1, meet: 10, distance: 2, depth: 2,
                            pathA: [Step(node: 1, kind: nil)], pathB: [Step(node: 2, kind: nil)], deeper: [])
        let c2 = Connection(a: 0, b: 1, meet: 11, distance: 3, depth: 3,
                            pathA: [Step(node: 1, kind: nil)], pathB: [Step(node: 2, kind: nil)], deeper: [])
        return SceneResponse(search: nil, words: words, connections: [c1, c2], semantic: semantic,
                             nodes: ["10": node(10, "*nókʷts"), "11": node(11, "*nekʷ-")])
    }

    private let anchors: [String: ARWordAnchor] = [
        "notte": ARWordAnchor(position: SIMD3(-0.2, 1, -1), distance: 1, seen: Date()),
        "night": ARWordAnchor(position: SIMD3(0.2, 1, -1), distance: 1, seen: Date()),
    ]

    func testRootsFloatAboveTheWordsTheyJoinWithoutOverlapping() throws {
        let layout = ARNetworkLayout(response: response(), anchors: anchors)
        XCTAssertEqual(layout.words.count, 2)  // aperta wasn't anchored
        XCTAssertEqual(layout.roots.map(\.node), [10, 11])
        for root in layout.roots {
            XCTAssertEqual(root.position.x, 0, accuracy: 1e-5)
            XCTAssertGreaterThan(root.position.y, 1.1)
            XCTAssertEqual(root.words, [0, 1])
        }
        let gap = simd_distance(layout.roots[0].position, layout.roots[1].position)
        XCTAssertGreaterThanOrEqual(gap, 0.1)
        XCTAssertTrue(layout.words[0]!.linked)
    }

    func testSameMeaningGoesInTheRootOrBecomesAnArc() {
        let shared = ARNetworkLayout(response: response(semantic: [SemanticLink(a: 0, b: 1, meaning: "night")]),
                                     anchors: anchors)
        XCTAssertEqual(shared.roots.first?.meaning, "night")
        XCTAssertTrue(shared.arcs.isEmpty)

        var both = anchors
        both["aperta"] = ARWordAnchor(position: SIMD3(0, 0.5, -1), distance: 1, seen: Date())
        let arc = ARNetworkLayout(response: response(semantic: [SemanticLink(a: 2, b: 1, meaning: "open")]),
                                  anchors: both)
        XCTAssertEqual(arc.arcs.map(\.meaning), ["open"])
        XCTAssertTrue(arc.words[2]!.linked)
    }
}
