import Observation
import simd
import UIKit

/// The people (and devices) talking around the phone, and the words each has said.
///
/// The backend tells voices apart; the camera says where each voice is. An utterance goes
/// to the face whose mouth moved while it was said, else to a screen or speaker in view,
/// else to "somewhere" off camera. A persona keeps the place it was given until it speaks
/// from somewhere else, and follows its face while the face is in view.
@MainActor
@Observable
final class Conversation {
    struct Persona: Identifiable, Equatable {
        let id: String  // the backend's voice: P1, P2…
        let number: Int  // order of first speaking, for its name and colour
        var source: SpeakerSource
        var position: SIMD3<Float>
        var distance: Float
        var lang: String?
        var words: [String] = []  // lowercased, in the order said; latest last
        var deviceKind: String?

        var color: UIColor { Conversation.palette[(number - 1) % Conversation.palette.count] }

        var title: String {
            switch source {
            case .face: return "Person \(number)"
            case .device: return Conversation.deviceName(deviceKind)
            case .somewhere: return "Voice \(number)"
            }
        }

        var symbol: String {
            switch source {
            case .face: return "person.fill"
            case .device: return deviceKind == "speakers_music" ? "hifispeaker.fill" : "tv"
            case .somewhere: return "waveform"
            }
        }
    }

    nonisolated static let palette: [UIColor] = [.systemPink, .systemTeal, .systemOrange, .systemPurple,
                                     .systemIndigo, .systemMint, .systemBrown]

    private(set) var personas: [Persona] = []
    private(set) var listening = false
    private(set) var connecting = false  // models load on the first connection
    private(set) var talking = false
    private(set) var error: String?
    /// The latest utterance, for the caption: who, and what.
    private(set) var caption: (persona: String, text: String)?

    let locator = SpeakerLocator()
    private let stream = ConversationStream()
    /// Hands an utterance to the scene (text, language); returns the words it brought.
    var onHeard: (String, String?) -> [String] = { _, _ in [] }

    init() {
        stream.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start() async {
        guard !listening else { return }
        error = nil
        connecting = true
        listening = true
        do {
            try await stream.start(base: APIClient.fromSettings().baseURL)
        } catch {
            self.error = error.localizedDescription
            listening = false
            connecting = false
        }
    }

    func stop() {
        guard listening else { return }
        stream.stop()
        listening = false
        connecting = false
        talking = false
    }

    /// The scene was cleared: the words go, the people stay.
    func clearWords() {
        for i in personas.indices { personas[i].words = [] }
        caption = nil
    }

    func persona(saying key: String) -> Persona? {
        personas.first { $0.words.contains(key) }
    }

    // MARK: events

    private func handle(_ event: ConversationStream.Event) {
        switch event {
        case .ready:
            connecting = false
        case .speech:
            talking = true
        case .silence:
            talking = false
        case .utterance(let u):
            connecting = false
            heard(u)
        case .failed(let message):
            if listening {
                error = "Lost the server: \(message)"
                stop()
            }
        }
    }

    private func heard(_ u: ConversationStream.Utterance) {
        var id = u.persona
        var source = SpeakerSource.somewhere
        if let start = stream.uptime(atStreamTime: u.start), let end = stream.uptime(atStreamTime: u.end) {
            source = locator.source(from: start, to: end).0
        }
        // the face already speaks for another voice: one person, heard as two voices
        if case .face = source, let same = personas.first(where: { $0.source == source && $0.id != id }),
           personas.allSatisfy({ $0.id != id }) {
            stream.merge(keep: same.id, drop: id)
            id = same.id
        }
        let words = onHeard(u.text, u.lang).map { $0.lowercased() }
        caption = (id, u.text)

        if let i = personas.firstIndex(where: { $0.id == id }) {
            // a voice heard again from a place the camera can see moves there; one heard
            // from nowhere visible stays where it was last seen
            if source != .somewhere { place(&personas[i], at: source) }
            if let lang = u.lang { personas[i].lang = lang }
        } else {
            var persona = Persona(id: id, number: personas.count + 1, source: .somewhere,
                                  position: .zero, distance: 1.5, lang: u.lang)
            place(&persona, at: source)
            personas.append(persona)
        }
        // a word belongs to whoever said it last
        let said = Set(words)
        for i in personas.indices where personas[i].id != id {
            personas[i].words.removeAll { said.contains($0) }
        }
        if let i = personas.firstIndex(where: { $0.id == id }) {
            personas[i].words.removeAll { said.contains($0) }
            personas[i].words += words
        }
    }

    private func place(_ persona: inout Persona, at source: SpeakerSource) {
        persona.source = source
        if case .device(let d) = source { persona.deviceKind = locator.device(d)?.kind }
        if let p = locator.position(of: source) {
            persona.position = p.position
            persona.distance = p.distance
        } else if let camera = locator.camera {
            // off camera: to one side, an arm's length or two away, alternating sides
            let others = personas.filter { $0.source == .somewhere && $0.id != persona.id }.count
            persona.position = Self.offCamera(camera: camera, slot: others)
            persona.distance = 1.6
        }
    }

    /// Follow the faces and devices the personas are bound to; true if any moved.
    @discardableResult
    func follow() -> Bool {
        var moved = false
        for i in personas.indices {
            guard personas[i].source != .somewhere,
                  let p = locator.position(of: personas[i].source) else { continue }
            if simd_distance(p.position, personas[i].position) > 0.005 {
                personas[i].position = p.position
                personas[i].distance = p.distance
                moved = true
            }
        }
        return moved
    }

    // MARK: layout

    /// Where a voice from outside the picture is put: in front, turned to the left or the
    /// right of where the camera looked (alternating), a little above eye level.
    nonisolated static func offCamera(camera: simd_float4x4, slot: Int) -> SIMD3<Float> {
        let origin = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        var forward = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        forward.y = 0
        forward = simd_length(forward) > 0.01 ? simd_normalize(forward) : SIMD3(0, 0, -1)
        let right = simd_cross(forward, SIMD3(0, 1, 0))
        let side: Float = slot % 2 == 0 ? 1 : -1
        let reach = Float(slot / 2) * 0.35
        return origin + forward * 1.6 + right * side * (0.55 + reach) + SIMD3(0, 0.15, 0)
    }

    /// Where a persona's words float: rows of three above the head (or device), the latest
    /// word in the lowest row nearest them, older ones rising above. Spacing grows with
    /// distance, so cards stay readable and apart.
    nonisolated static func wordPositions(count: Int, around head: SIMD3<Float>, distance: Float,
                              right: SIMD3<Float>) -> [SIMD3<Float>] {
        let d = max(distance, 0.5)
        let across = simd_length(right) > 0.01 ? simd_normalize(right) : SIMD3(1, 0, 0)
        let columns: [Float] = [0, -1, 1]
        return (0..<count).map { i in
            let fromLatest = count - 1 - i
            let row = Float(fromLatest / 3)
            let column = columns[fromLatest % 3]
            return head + SIMD3(0, (0.17 + 0.075 * row) * d, 0) + across * column * 0.13 * d
        }
    }

    /// The anchors of the spoken words still in the scene, for the AR layout, laid out
    /// across the camera's view.
    func anchors(camera: simd_float4x4, scene: Set<String>, now: Date = Date()) -> [String: ARWordAnchor] {
        let right = SIMD3(camera.columns.0.x, 0, camera.columns.0.z)
        var out: [String: ARWordAnchor] = [:]
        for p in personas {
            let words = p.words.filter { scene.contains($0) }
            let spots = Self.wordPositions(count: words.count, around: p.position,
                                           distance: p.distance, right: right)
            for (key, spot) in zip(words, spots) {
                out[key] = ARWordAnchor(position: spot, distance: p.distance, seen: now)
            }
        }
        return out
    }

    nonisolated static func deviceName(_ kind: String?) -> String {
        switch kind {
        case "television": return "TV"
        case "laptop", "computer", "computer_monitor": return "Computer"
        case "phone": return "Phone"
        case "speakers_music": return "Speaker"
        default: return "Device"
        }
    }
}
