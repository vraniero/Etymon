import Accelerate
import Foundation

/// A voice, summed up from a stretch of speech, to tell speakers apart on the phone (the
/// server uses a neural speaker model; this is the classic recipe): the shape of the voice
/// (the average and spread of its MFCCs, mel-frequency cepstral coefficients) and how
/// high it is (median pitch). Two utterances by one person land close together.
enum VoicePrint {
    static let coefficients = 13
    private static let frame = 400  // 25 ms at 16 kHz
    private static let hop = 160  // 10 ms
    private static let fftSize = 512
    private static let filters = 26

    /// The voice in 16 kHz mono samples; nil when there's too little voiced sound.
    static func embedding(_ samples: [Float], rate: Double = 16_000) -> [Float]? {
        guard samples.count >= frame * 4 else { return nil }
        let frames = stride(from: 0, to: samples.count - frame, by: hop).map {
            Array(samples[$0..<$0 + frame])
        }
        let energies = frames.map { rms($0) }
        // the louder frames: voiced speech, not the pauses between words
        let cut = energies.sorted()[energies.count * 4 / 10]
        let voiced = zip(frames, energies).filter { $0.1 >= cut && $0.1 > 0.003 }.map(\.0)
        guard voiced.count >= 10 else { return nil }

        let mfccs = voiced.map { mfcc($0, rate: rate) }
        var mean = [Float](repeating: 0, count: coefficients)
        var spread = [Float](repeating: 0, count: coefficients)
        for c in 0..<coefficients {
            let values = mfccs.map { $0[c] }
            let m = values.reduce(0, +) / Float(values.count)
            mean[c] = m
            spread[c] = (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(values.count)).squareRoot()
        }
        let pitches = voiced.compactMap { pitch($0, rate: rate) }.sorted()
        let f0 = pitches.isEmpty ? 150 : pitches[pitches.count / 2]
        // pitch on a log scale, weighted to count about as much as the spectral shape
        return mean + spread.map { $0 * 0.5 } + [log2(f0 / 150) * 12]
    }

    /// How far apart two voices are (0: the same).
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
    }

    static func rms(_ x: [Float]) -> Float {
        (x.map { $0 * $0 }.reduce(0, +) / Float(max(x.count, 1))).squareRoot()
    }

    // MARK: MFCC

    private static let window: [Float] = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                                     count: frame, isHalfWindow: false)
    private static let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!  // 2^9 = 512

    private static func melBank(rate: Double) -> [[Float]] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let low = mel(80), high = mel(min(7600, rate / 2 - 100))
        let points = (0...filters + 1).map { hz(low + (high - low) * Double($0) / Double(filters + 1)) }
        let bins = points.map { Int(($0 / rate) * Double(fftSize)) }
        return (0..<filters).map { i in
            var row = [Float](repeating: 0, count: fftSize / 2)
            let (a, b, c) = (bins[i], bins[i + 1], bins[i + 2])
            for k in a..<b where b > a && k < row.count { row[k] = Float(k - a) / Float(b - a) }
            for k in b..<c where c > b && k < row.count { row[k] = Float(c - k) / Float(c - b) }
            return row
        }
    }

    private static var banks: [Double: [[Float]]] = [:]
    private static let bankLock = NSLock()

    private static func mfcc(_ x: [Float], rate: Double) -> [Float] {
        var padded = vDSP.multiply(x, window) + [Float](repeating: 0, count: fftSize - frame)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                padded.withUnsafeMutableBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                              vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
            }
        }
        let bank = bankLock.withLock { () -> [[Float]] in
            if let bank = banks[rate] { return bank }
            let bank = melBank(rate: rate)
            banks[rate] = bank
            return bank
        }
        let logMel = bank.map { log(max(vDSP.dot($0, power), 1e-10)) }
        // DCT-II, leaving out c0 (overall loudness)
        return (1...coefficients).map { k in
            var sum: Float = 0
            for (m, value) in logMel.enumerated() {
                sum += value * cos(Float.pi * Float(k) * (Float(m) + 0.5) / Float(filters))
            }
            return sum
        }
    }

    /// The pitch of a voiced frame by autocorrelation, 60–400 Hz; nil when unclear.
    private static func pitch(_ x: [Float], rate: Double) -> Float? {
        let minLag = Int(rate / 400), maxLag = min(Int(rate / 60), x.count - 1)
        let energy = vDSP.dot(x, x)
        guard energy > 0, maxLag > minLag else { return nil }
        var best: (lag: Int, r: Float) = (0, 0)
        for lag in minLag...maxLag {
            let r = vDSP.dot(Array(x[0..<x.count - lag]), Array(x[lag...])) / energy
            if r > best.r { best = (lag, r) }
        }
        return best.r > 0.3 ? Float(rate) / Float(best.lag) : nil
    }
}

/// The voices heard so far, each a persona (P1, P2…): a voice near enough to one known is
/// that persona and refines it; otherwise a new one begins. As backend/listen.py's Voices,
/// with distances between voice prints instead of a neural model's similarities.
final class Voices: @unchecked Sendable {
    final class Persona {
        let id: String
        var centroid: [Float]
        var count = 1
        var lang: String?
        init(id: String, centroid: [Float]) {
            self.id = id
            self.centroid = centroid
        }
    }

    /// Voice prints closer than this are one speaker (tuned on recorded voices: one speaker
    /// across sentences lies well within it, different speakers beyond).
    var threshold: Float
    private(set) var personas: [Persona] = []
    private var next = 1
    private let lock = NSLock()

    init(threshold: Float = Voices.defaultThreshold) {
        self.threshold = threshold
    }

    static let defaultThreshold: Float = 14

    /// The persona a voice belongs to (nil: new) and how similar, 0…1.
    func match(_ print: [Float]) -> (Persona?, Double) {
        lock.withLock {
            guard let (best, d) = personas.map({ ($0, VoicePrint.distance(print, $0.centroid)) })
                .min(by: { $0.1 < $1.1 }) else { return (nil, 0) }
            let similarity = Double(max(0, 1 - d / (2 * threshold)))
            return (d <= threshold ? best : nil, similarity)
        }
    }

    /// Match and learn: refine the persona, or begin a new one.
    func assign(_ print: [Float]) -> (Persona, isNew: Bool, similarity: Double) {
        let (found, similarity) = match(print)
        return lock.withLock {
            if let found {
                let weight = 1 / Float(min(found.count + 1, 10))
                found.centroid = zip(found.centroid, print).map { (1 - weight) * $0 + weight * $1 }
                found.count += 1
                return (found, false, similarity)
            }
            let persona = Persona(id: "P\(next)", centroid: print)
            next += 1
            personas.append(persona)
            return (persona, true, similarity)
        }
    }

    /// Two voices turned out to be one person.
    func merge(keep: String, drop: String) {
        lock.withLock {
            guard let a = personas.first(where: { $0.id == keep }),
                  let b = personas.first(where: { $0.id == drop }), a !== b else { return }
            let total = Float(a.count + b.count)
            a.centroid = zip(a.centroid, b.centroid).map { ($0 * Float(a.count) + $1 * Float(b.count)) / total }
            a.count += b.count
            personas.removeAll { $0 === b }
        }
    }
}
