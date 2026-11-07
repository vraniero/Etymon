import AVFoundation
import Foundation

/// Streams the microphone to the backend's /listen and hands back what it hears: when
/// someone starts and stops talking, and each utterance with its words, its language and
/// the persona (voice) that said it.
///
/// The backend counts time in seconds of audio received; `uptime(atStreamTime:)` turns
/// that into the clock ARKit stamps its frames with, so an utterance can be lined up with
/// what the camera saw while it was said.
final class ConversationStream: @unchecked Sendable {
    struct Word: Decodable, Hashable {
        let text: String
        let start: Double
        let end: Double
    }

    struct Utterance: Decodable {
        let id: Int
        let persona: String
        let newPersona: Bool
        let similarity: Double
        let lang: String?
        /// What Whisper heard, even a language the backend doesn't know ("ja").
        let detected: String?
        let start: Double
        let end: Double
        let text: String
        let words: [Word]
    }

    enum Event {
        /// Models loaded; the languages it understands.
        case ready(languages: [String])
        case speech(at: Double)
        /// Someone stopped; `kept`: long enough to be transcribed (an utterance or `unheard`
        /// follows), not a click.
        case silence(at: Double, kept: Bool)
        /// A sound transcribed to no words.
        case unheard
        case utterance(Utterance)
        case failed(String)
    }

    enum StreamError: LocalizedError {
        case denied, noMicrophone, badURL
        var errorDescription: String? {
            switch self {
            case .denied: return "Microphone access is off: allow it in Settings."
            case .noMicrophone: return "No microphone available."
            case .badURL: return "The server address isn't valid."
            }
        }
    }

    /// Called on the main actor.
    var onEvent: (@MainActor (Event) -> Void)?
    /// How loud the microphone is, 0…1, about 12 times a second. Called on the main actor.
    var onLevel: (@MainActor (Float) -> Void)?
    private var lastLevel: TimeInterval = 0

    static let sampleRate = 16_000.0
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                       channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var origin: TimeInterval?  // uptime of the first sample streamed

    /// The listening endpoint of a backend: http://mac:8000 -> ws://mac:8000/listen.
    static func url(base: URL) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("listen"),
                                       resolvingAgainstBaseURL: false)
        components?.scheme = base.scheme == "https" ? "wss" : "ws"
        return components?.url
    }

    /// When a moment of the stream happened, on ARKit's clock (seconds of system uptime).
    func uptime(atStreamTime t: Double) -> TimeInterval? {
        lock.withLock { origin.map { $0 + t } }
    }

    func start(base: URL) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw StreamError.denied }
        guard let url = Self.url(base: base) else { throw StreamError.badURL }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw StreamError.noMicrophone }
        let task = URLSession.shared.webSocketTask(with: url)
        lock.withLock {
            self.task = task
            origin = nil
            converter = AVAudioConverter(from: format, to: target)
        }
        task.resume()
        receive(task)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.send(buffer, at: when)
            self?.measure(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel(with: .goingAway, reason: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Two voices turned out to be one person (the same face spoke with both).
    func merge(keep: String, drop: String) {
        command(["type": "merge", "keep": keep, "drop": drop])
    }

    private func command(_ body: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.withLock { task }?.send(.string(text)) { _ in }
    }

    // MARK: audio out

    /// Loudness on a speech-friendly scale: -55 dB (a quiet room) is 0, -10 dB is 1.
    static func level(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 55) / 45, 0), 1)
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevel >= 0.08, let samples = buffer.floatChannelData?[0],
              buffer.frameLength > 0 else { return }
        lastLevel = now
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let level = Self.level(rms: (sum / Float(buffer.frameLength)).squareRoot())
        Task { @MainActor [onLevel] in onLevel?(level) }
    }

    private func send(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        let (task, converter) = lock.withLock { (self.task, self.converter) }
        guard let task, let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        lock.withLock {
            if origin == nil {
                origin = when.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: when.hostTime)
                    : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / buffer.format.sampleRate
            }
        }
        task.send(.data(Data(bytes: samples[0], count: Int(out.frameLength) * 2))) { _ in }
    }

    // MARK: events in

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            let current = self.lock.withLock { self.task === task }
            guard current else { return }
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let bytes): data = bytes
                @unknown default: data = nil
                }
                if let data, let event = Self.event(from: data) { self.emit(event) }
                self.receive(task)
            case .failure(let error):
                self.emit(.failed(error.localizedDescription))
            }
        }
    }

    static func event(from data: Data) -> Event? {
        struct Kind: Decodable {
            let type: String
            let start: Double?
            let end: Double?
            let kept: Bool?
            let languages: [String]?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let kind = try? decoder.decode(Kind.self, from: data) else { return nil }
        switch kind.type {
        case "ready": return .ready(languages: kind.languages ?? [])
        case "speech": return kind.start.map { .speech(at: $0) }
        case "silence": return kind.end.map { .silence(at: $0, kept: kind.kept ?? true) }
        case "unheard": return .unheard
        case "utterance": return (try? decoder.decode(Utterance.self, from: data)).map { .utterance($0) }
        default: return nil
        }
    }

    private func emit(_ event: Event) {
        Task { @MainActor [onEvent] in onEvent?(event) }
    }
}
