import SceneKit
import UIKit

/// A word (and its language, and optionally a shared meaning) drawn into a rounded card,
/// for the 3D views: Explore and AR.
enum SceneLabel {
    static func image(word: String, language: String, meaning: String? = nil,
                      reconstructed: Bool, fill: UIColor) -> UIImage {
        let font = reconstructed
            ? UIFont.italicSystemFont(ofSize: 34).withWeight(.semibold)
            : UIFont.systemFont(ofSize: 34, weight: .semibold)
        let small = UIFont.systemFont(ofSize: 20, weight: .regular)
        let meaningFont = UIFont.systemFont(ofSize: 22, weight: .semibold)
        let lines: [(NSString, [NSAttributedString.Key: Any])] = [
            (word as NSString, [.font: font, .foregroundColor: UIColor.black]),
            (language as NSString, [.font: small, .foregroundColor: UIColor.black.withAlphaComponent(0.6)]),
        ] + (meaning.map {
            [("= \($0)" as NSString,
              [.font: meaningFont, .foregroundColor: UIColor(red: 0.0, green: 0.5, blue: 0.2, alpha: 1)])]
        } ?? [])
        let sizes = lines.map { $0.0.size(withAttributes: $0.1) }
        let size = CGSize(width: (sizes.map(\.width).max() ?? 0) + 36,
                          height: sizes.map(\.height).reduce(0, +) + 18)
        return UIGraphicsImageRenderer(size: size).image { _ in
            fill.withAlphaComponent(0.92).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 14).fill()
            var y: CGFloat = 6
            for (line, s) in zip(lines, sizes) {
                line.0.draw(at: CGPoint(x: (size.width - s.width) / 2, y: y), withAttributes: line.1)
                y += s.height
            }
        }
    }

    /// The card on a double-sided, unlit plane; `pointsPerUnit` sets its size in the scene.
    static func plane(word: String, language: String, meaning: String? = nil,
                      reconstructed: Bool, fill: UIColor, pointsPerUnit: CGFloat) -> SCNPlane {
        let image = image(word: word, language: language, meaning: meaning,
                          reconstructed: reconstructed, fill: fill)
        let plane = SCNPlane(width: image.size.width / pointsPerUnit,
                             height: image.size.height / pointsPerUnit)
        plane.firstMaterial?.diffuse.contents = image
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.isDoubleSided = true
        return plane
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// Labels in AR that face the camera and stay upright for whoever holds the phone: like
/// SCNBillboardConstraint, plus a roll that turns them when the phone goes landscape
/// (the app's screens stay portrait, so the camera's "up" turns with the phone).
enum UprightLabel {
    private struct Turn {
        var from: Float = 0
        var to: Float = 0
        var start: CFTimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var turn = Turn()
    nonisolated(unsafe) private static weak var camera: SCNNode?
    /// How long a turn to the new orientation takes, like the system's own rotation.
    static let duration: CFTimeInterval = 0.3

    /// The view's point of view, which labels face.
    static func follow(_ pointOfView: SCNNode?) {
        lock.lock(); defer { lock.unlock() }
        camera = pointOfView
    }

    /// Turn every label to `roll` (radians, anticlockwise on screen), easing from where it is.
    static func set(roll: Float, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock(); defer { lock.unlock() }
        let current = value(turn, at: now)
        guard abs(current - roll) > 0.001 || abs(turn.to - roll) > 0.001 else { return }
        // take the short way round (upside down from landscape: a quarter turn, not three)
        var target = roll
        while target - current > .pi { target -= 2 * .pi }
        while target - current < -.pi { target += 2 * .pi }
        turn = Turn(from: current, to: target, start: now)
    }

    static func roll(at now: CFTimeInterval = CACurrentMediaTime()) -> Float {
        lock.lock(); defer { lock.unlock() }
        return value(turn, at: now)
    }

    private static func value(_ t: Turn, at now: CFTimeInterval) -> Float {
        let k = Float(min(max((now - t.start) / duration, 0), 1))
        let eased = k * k * (3 - 2 * k)  // smoothstep
        return t.from + (t.to - t.from) * eased
    }

    /// Use instead of SCNBillboardConstraint.
    static func constraint() -> SCNConstraint {
        SCNTransformConstraint.orientationConstraint(inWorldSpace: true) { _, orientation in
            lock.lock()
            let facing = camera?.presentation.simdWorldOrientation
            let r = value(turn, at: CACurrentMediaTime())
            lock.unlock()
            guard let facing else { return orientation }
            let rolled = facing * simd_quatf(angle: r, axis: SIMD3(0, 0, 1))
            return SCNQuaternion(rolled.imag.x, rolled.imag.y, rolled.imag.z, rolled.real)
        }
    }
}
