import AVFoundation

/// The sound of a connection being made: a bell when two words meet in a shared root, two
/// soft rising notes when they mean the same. Each new connection takes the next note of a
/// pentatonic scale, so a lively conversation plays a small, never-clashing melody.
///
/// Synthesized, not recorded: bell partials with an exponential decay. Short and quiet,
/// so the microphone listening at the same time doesn't take it for speech.
@MainActor
final class Chimes {
    enum Kind { case root, meaning }

    static let storageKey = "talkSound"

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var note = 0
    private var lastPlayed = Date.distantPast

    /// Semitones above A4 of a major pentatonic scale over two octaves (C D E G A …).
    static let scale = [3, 5, 7, 10, 12, 15, 17, 19, 22, 24]

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.35
    }

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }

    func play(_ kind: Kind) {
        guard Self.isOn else { return }
        // several at once (a scene answer with many links) would be a clatter: space them
        let now = Date()
        let delay = max(0, 0.18 - now.timeIntervalSince(lastPlayed))
        lastPlayed = now.addingTimeInterval(delay)
        let frequency = 440 * pow(2, Double(Self.scale[note % Self.scale.count]) / 12)
        note += 1
        guard let buffer = kind == .root ? bell(frequency) : pair(frequency) else { return }
        do {
            if !engine.isRunning {
                let session = AVAudioSession.sharedInstance()
                if session.category != .playAndRecord {  // listening has set up the session already
                    try session.setCategory(.ambient, options: [.mixWithOthers])
                }
                try session.setActive(true)
                try engine.start()
            }
            let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay))
            player.scheduleBuffer(buffer, at: delay > 0 ? when : nil)
            if !player.isPlaying { player.play() }
        } catch {
            // no sound is no harm
        }
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    /// A struck bell: a fundamental and inharmonic partials, the higher ones dying faster.
    private func bell(_ f: Double) -> AVAudioPCMBuffer? {
        render(seconds: 0.9) { t in
            let partials: [(ratio: Double, amp: Double, decay: Double)] =
                [(1, 0.6, 3.2), (2.76, 0.25, 6), (5.4, 0.12, 9), (0.5, 0.15, 2.5)]
            return partials.reduce(0) { sum, p in
                sum + p.amp * exp(-p.decay * t) * sin(2 * .pi * f * p.ratio * t)
            }
        }
    }

    /// Two soft notes a fifth apart: the second answering the first.
    private func pair(_ f: Double) -> AVAudioPCMBuffer? {
        render(seconds: 0.7) { t in
            func tone(_ freq: Double, from start: Double) -> Double {
                let u = t - start
                guard u >= 0 else { return 0 }
                let attack = min(u / 0.02, 1)
                return attack * exp(-5 * u) * (sin(2 * .pi * freq * u) + 0.2 * sin(4 * .pi * freq * u))
            }
            return 0.45 * (tone(f, from: 0) + tone(f * 1.5, from: 0.14))
        }
    }

    private func render(seconds: Double, _ wave: (Double) -> Double) -> AVAudioPCMBuffer? {
        let count = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = count
        for i in 0..<Int(count) {
            let t = Double(i) / format.sampleRate
            let fadeOut = min(1, (seconds - t) / 0.05)  // no click at the end
            samples[i] = Float(wave(t) * fadeOut)
        }
        return buffer
    }
}
