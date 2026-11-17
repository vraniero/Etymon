import AVFoundation
import CoreMedia
import Foundation
import NaturalLanguage
import Speech

/// Talk without a server: the microphone transcribed on the phone, turned into the events
/// the backend's /listen sends (ConversationStream.Event), so Talk works the same either way.
///
/// Like the server, it works out per utterance who is speaking and in which language:
/// - the stream is cut into utterances at pauses (Segmenter, as backend/listen.py);
/// - every candidate language has its own recognizer listening to the whole stream; at
///   the end of an utterance each one's transcript is scored (the recognizer's own
///   confidence, how much the text reads like that language, how many of its words the
///   dictionary has in it, and the language the speaker used last) and the best is kept;
/// - the voice is summed up (VoicePrint) and matched against the voices heard so far.
final class OnDeviceSpeech: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noLanguage, noFormat, noMicrophone
        var errorDescription: String? {
            switch self {
            case .noLanguage: return "This phone can't transcribe any of Etymon's languages."
            case .noFormat: return "Speech recognition isn't available."
            case .noMicrophone: return "No microphone available."
            }
        }
    }

    /// Each event, as the server would send it.
    var emit: (ConversationStream.Event) -> Void = { _ in }
    /// Each utterance's transcripts, one per language, scored (for tests and tuning).
    var onCandidates: ([Candidate]) -> Void = { _ in }
    /// Every microphone buffer, for the level meter and the clock.
    var onBuffer: (AVAudioPCMBuffer, AVAudioTime) -> Void = { _, _ in }

    // MARK: languages

    /// The languages Talk listens for (Wiktionary codes), remembered.
    static let languagesKey = "talkLanguages"
    /// Recognizers running at once: each costs battery and time.
    static let maxLanguages = 3
    /// Auto: when an utterance fits none of the languages listened for, try the likeliest
    /// others, and listen for the one that fits from then on. Remembered; on by default.
    static let autoKey = "talkAutoLanguages"
    static var autoDetects: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    /// A transcript scoring this much fits its language (a right one scores ~3, the same
    /// speech heard as another language ~1).
    static let fits = 2.0

    /// The system's code for a Wiktionary one: sh -> hr.
    static func systemID(_ code: String) -> String {
        WordExtractor.systemCodes[code]?.first ?? code
    }

    static func locale(for code: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: systemID(code)))
    }

    /// Etymon's languages this phone can transcribe, in Etymon's order.
    static func available() async -> [String] {
        var out: [String] = []
        for code in WordExtractor.languages where await locale(for: code) != nil { out.append(code) }
        return out
    }

    /// The languages to listen for: those chosen in Talk, else the phone's own and English.
    static func chosen() async -> [String] {
        let can = await available()
        let stored = (UserDefaults.standard.stringArray(forKey: languagesKey) ?? []).filter(can.contains)
        if !stored.isEmpty { return Array(stored.prefix(maxLanguages)) }
        let phone = Locale.preferredLanguages.map { WordExtractor.code(forSystem: $0) } + ["en", "it"]
        return Array(LocalBackend.unique(phone.filter(can.contains)).prefix(2))
    }

    /// An app may keep models for a few languages only: these are reserved, making room
    /// by letting go of languages no longer listened for. Without a reservation the system
    /// won't download a language's model (only the phone's own languages come anyway).
    static func reserve(_ wanted: [Locale]) async {
        var reserved = await AssetInventory.reservedLocales
        for locale in wanted where !reserved.contains(where: { $0.identifier == locale.identifier }) {
            if reserved.count >= AssetInventory.maximumReservedLocales,
               let spare = reserved.first(where: { r in !wanted.contains { $0.identifier == r.identifier } }) {
                await AssetInventory.release(reservedLocale: spare)
                reserved.removeAll { $0.identifier == spare.identifier }
            }
            if (try? await AssetInventory.reserve(locale: locale)) == true { reserved.append(locale) }
        }
    }

    // MARK: listening

    private struct Utterance {
        let start: Double
        let end: Double
        let samples: [Float]
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    /// The languages listened for, and the locale each is transcribed in.
    private var languages: [(code: String, locale: Locale)] = []
    /// Auto (see `autoKey`), and what it needs: every language the phone can transcribe,
    /// when each language was last heard, and the models being fetched.
    var autoDetect = OnDeviceSpeech.autoDetects
    private var transcribable: [String] = []
    private var lastHeard: [String: Date] = [:]
    private var fetching = Set<String>()
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var segmenter = Segmenter(rate: 16_000)
    private var utterances: AsyncStream<Utterance>.Continuation?
    private var working: Task<Void, Never>?
    private let voices = Voices()
    private var nextID = 1
    /// The dictionary, to see which language a transcript's words belong to.
    var dictionary: LocalBackend? = LocalBackend.shared

    /// Ready the recognizers for these languages (downloading their models if needed).
    /// Returns the languages it will listen for.
    @discardableResult
    func prepare(languages: [String]? = nil) async throws -> [String] {
        var codes = languages ?? []
        if languages == nil { codes = await Self.chosen() }
        var pairs: [(String, SpeechTranscriber)] = []
        var lastError: Error?
        var locales: [String: Locale] = [:]
        for code in codes { locales[code] = await Self.locale(for: code) }
        await Self.reserve(Array(locales.values))
        for code in codes {
            guard let locale = locales[code] else { continue }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            // each language's model on its own: one that can't be had leaves the others
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                pairs.append((code, transcriber))
            } catch {
                lastError = error
            }
        }
        guard !pairs.isEmpty else { throw lastError ?? Failure.noLanguage }
        let modules = pairs.map(\.1)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw Failure.noFormat
        }
        let can = autoDetect ? await Self.available() : []
        let (queue, utterances) = AsyncStream.makeStream(of: Utterance.self)
        let chosen = pairs.map { ($0.0, $0.1.selectedLocales.first ?? locales[$0.0]!) }
        lock.withLock {
            self.languages = chosen
            transcribable = can
            self.format = format
            segmenter = Segmenter(rate: format.sampleRate)
            self.utterances = utterances
        }
        working = Task { [weak self] in
            for await utterance in queue { await self?.understand(utterance) }
        }
        return chosen.map(\.0)
    }

    /// Start the microphone (after `prepare`).
    func startMicrophone() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        let mic = engine.inputNode
        let natural = mic.outputFormat(forBus: 0)
        guard natural.sampleRate > 0 else { throw Failure.noMicrophone }
        mic.removeTap(onBus: 0)
        mic.installTap(onBus: 0, bufferSize: 4096, format: natural) { [weak self] buffer, when in
            self?.onBuffer(buffer, when)
            self?.feed(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Listen: the languages chosen, the microphone on. Returns the languages.
    func start() async throws -> [String] {
        let codes = try await prepare()
        try startMicrophone()
        return codes
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        let utterances = lock.withLock { () -> AsyncStream<Utterance>.Continuation? in
            defer {
                self.utterances = nil
                converter = nil
            }
            return self.utterances
        }
        utterances?.finish()
        working?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The end of the audio (a file in tests): the last utterance, then everything understood.
    func finish() async {
        let (events, utterances) = lock.withLock { (segmenter.flush(), self.utterances) }
        handle(events)
        utterances?.finish()
        await working?.value
    }

    func merge(keep: String, drop: String) { voices.merge(keep: keep, drop: drop) }

    /// Audio in any format: converted for the recognizers, and cut into utterances.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let (format, listening) = lock.withLock { (self.format, !self.languages.isEmpty) }
        guard let format, listening else { return }
        let converter = lock.withLock { () -> AVAudioConverter? in
            if self.converter == nil || self.converter?.inputFormat != buffer.format {
                self.converter = AVAudioConverter(from: buffer.format, to: format)
            }
            return self.converter
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
        guard error == nil, out.frameLength > 0 else { return }
        let events = lock.withLock { segmenter.feed(Self.samples(out)) }
        handle(events)
    }

    private func handle(_ events: [Segmenter.Event]) {
        for event in events {
            switch event {
            case .speech(let at): emit(.speech(at: at))
            case .silence(let at, let kept): emit(.silence(at: at, kept: kept))
            case .utterance(let start, let samples):
                let rate = lock.withLock { format?.sampleRate ?? 16_000 }
                let utterance = Utterance(start: start, end: start + Double(samples.count) / rate, samples: samples)
                _ = lock.withLock { utterances?.yield(utterance) }
            }
        }
    }

    static func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buffer.frameLength)
        if let floats = buffer.floatChannelData { return Array(UnsafeBufferPointer(start: floats[0], count: n)) }
        if let ints = buffer.int16ChannelData {
            return UnsafeBufferPointer(start: ints[0], count: n).map { Float($0) / 32768 }
        }
        return []
    }

    // MARK: understanding an utterance

    struct Candidate {
        var parts: [String: Double] = [:]
        let code: String
        let words: [ConversationStream.Word]
        let confidence: Double
        var score: Double = 0
        var text: String { words.map(\.text).joined(separator: " ") }
    }

    private func understand(_ utterance: Utterance) async {
        let (languages, format) = lock.withLock { (self.languages, self.format) }
        guard let format, let buffer = Self.buffer(utterance.samples, format: format) else { return }
        // the utterance heard in each language, one after another: the phone runs only so
        // many recognizers at once, and a third one at the same time hears nothing
        var candidates: [Candidate] = []
        for (code, locale) in languages {
            candidates.append(await Self.transcribe(buffer, code: code, locale: locale, offset: utterance.start))
        }
        let print = VoicePrint.embedding(utterance.samples, rate: format.sampleRate)
        let known = print.flatMap { voices.match($0).0 }
        await score(&candidates, speakerLanguage: known?.lang)
        let fitting = candidates.map(\.score).max() ?? 0
        if autoDetect, fitting < Self.fits, candidates.contains(where: { !$0.words.isEmpty }) {
            // fits none of them: perhaps another language
            candidates += await discover(buffer, utterance: utterance, heard: candidates)
            await score(&candidates, speakerLanguage: known?.lang)
        }
        onCandidates(candidates)
        guard let best = candidates.filter({ !$0.words.isEmpty }).max(by: { $0.score < $1.score }) else {
            emit(.unheard)
            return
        }
        lock.withLock { lastHeard[best.code] = Date() }
        if !languages.contains(where: { $0.code == best.code }), best.score >= Self.fits {
            await listen(for: best.code)
        }
        // too little voice to tell (a word or two): the speaker it sounds closest to, or a new one
        let (persona, isNew, similarity): (Voices.Persona, Bool, Double)
        if let print {
            (persona, isNew, similarity) = voices.assign(print)
        } else if let last = voices.personas.last {
            (persona, isNew, similarity) = (last, false, 0)
        } else {
            (persona, isNew, similarity) = voices.assign([Float](repeating: 0, count: VoicePrint.coefficients * 2 + 1))
        }
        persona.lang = best.code
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        emit(.utterance(.init(id: id, persona: persona.id, newPersona: isNew, similarity: similarity,
                              lang: best.code, detected: best.code, start: utterance.start,
                              end: utterance.end, text: best.text, words: best.words)))
    }

    /// Other languages tried on an utterance that fits none of those listened for: the ones
    /// its transcripts read most like (German heard as English still looks German), else
    /// the most spoken. Only languages whose model is on the phone are tried now; the
    /// model of one that isn't is fetched, for next time.
    private func discover(_ buffer: AVAudioPCMBuffer, utterance: Utterance, heard: [Candidate]) async -> [Candidate] {
        let (current, can) = lock.withLock { (Set(languages.map(\.code)), transcribable) }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = can.map { NLLanguage(Self.systemID($0)) }
        var likely: [String: Double] = [:]
        for c in heard where !c.words.isEmpty {
            recognizer.reset()
            recognizer.processString(c.text)
            for (lang, p) in recognizer.languageHypotheses(withMaximum: 5) {
                let code = WordExtractor.code(forSystem: lang.rawValue)
                likely[code, default: 0] += p
            }
        }
        let ranked = likely.sorted { $0.value > $1.value }.map(\.key)
        let guesses = LocalBackend.unique(ranked + ["en", "it", "es", "fr", "de", "ru", "pl"])
            .filter { !current.contains($0) && can.contains($0) }.prefix(2)
        var found: [Candidate] = []
        for code in guesses {
            guard let locale = await Self.locale(for: code) else { continue }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                                attributeOptions: [.audioTimeRange])
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                fetch(code, locale: locale)
                continue
            }
            found.append(await Self.transcribe(buffer, code: code, locale: locale, offset: utterance.start))
        }
        return found
    }

    /// Fetch a language's model in the background (once).
    private func fetch(_ code: String, locale: Locale) {
        guard lock.withLock({ fetching.insert(code).inserted }) else { return }
        let keep = lock.withLock { languages.map(\.locale) }
        Task {
            await Self.reserve(keep + [locale])
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                                attributeOptions: [.audioTimeRange])
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try? await request.downloadAndInstall()
            }
            _ = lock.withLock { fetching.remove(code) }
        }
    }

    /// Listen for a language from now on; past the most at once, the one heard longest
    /// ago makes way. Remembered, and told (an event).
    private func listen(for code: String) async {
        guard let locale = await Self.locale(for: code) else { return }
        let codes = lock.withLock { () -> [String] in
            languages.append((code, locale))
            if languages.count > Self.maxLanguages,
               let oldest = languages.filter({ $0.code != code })
                   .min(by: { (lastHeard[$0.code] ?? .distantPast) < (lastHeard[$1.code] ?? .distantPast) }) {
                languages.removeAll { $0.code == oldest.code }
            }
            return languages.map(\.code)
        }
        UserDefaults.standard.set(codes, forKey: Self.languagesKey)
        emit(.languages(codes, added: code))
    }

    /// Each candidate's score: the recognizer's confidence (0…1), how much the text reads
    /// like its language (0…1), the share of its words in the dictionary in that language
    /// (0…1), and a little for the language the speaker spoke last.
    func score(_ candidates: inout [Candidate], speakerLanguage: String?) async {
        let codes = candidates.map(\.code)
        for i in candidates.indices where !candidates[i].words.isEmpty {
            let c = candidates[i]
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = codes.map { NLLanguage(Self.systemID($0)) }
            recognizer.processString(c.text)
            let reads = recognizer.languageHypotheses(withMaximum: codes.count)[NLLanguage(Self.systemID(c.code))] ?? 0
            let words = WordExtractor.words(in: c.text)
            var found = 0.0
            if let dictionary, !words.isEmpty {
                found = await dictionary.knownShare(of: words, in: c.code)
            }
            candidates[i].score = c.confidence + reads + found + (speakerLanguage == c.code ? 0.2 : 0)
            candidates[i].parts = ["conf": c.confidence, "reads": Double(reads), "dict": found]
        }
    }

    /// One utterance in one language: its words (times in the stream) and how sure the
    /// recognizer is of them.
    static func transcribe(_ buffer: AVAudioPCMBuffer, code: String, locale: Locale,
                           offset: Double) async -> Candidate {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collecting = Task { () -> [SpeechTranscriber.Result] in
            var out: [SpeechTranscriber.Result] = []
            do { for try await r in transcriber.results { out.append(r) } } catch {}
            return out
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input.yield(AnalyzerInput(buffer: buffer))
        input.finish()
        do {
            if let last = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        let results = await collecting.value
        let words = results.flatMap { words(in: $0.text) }.map {
            ConversationStream.Word(text: $0.text, start: $0.start + offset, end: $0.end + offset)
        }
        let confidences = results.flatMap { confidences(in: $0.text) }
        return Candidate(code: code, words: words,
                         confidence: confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count))
    }

    /// Samples as a buffer in the recognizers' format.
    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let floats = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { floats[0].update(from: $0.baseAddress!, count: samples.count) }
        } else if let ints = buffer.int16ChannelData {
            for (i, v) in samples.enumerated() { ints[0][i] = Int16(max(-1, min(1, v)) * 32767) }
        } else {
            return nil
        }
        return buffer
    }

    static func words(in text: AttributedString) -> [ConversationStream.Word] {
        var out: [ConversationStream.Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
            for token in piece.split(whereSeparator: \.isWhitespace) {
                out.append(.init(text: String(token), start: range?.start.seconds ?? 0,
                                 end: range.map { CMTimeRangeGetEnd($0).seconds } ?? 0))
            }
        }
        return out
    }

    static func confidences(in text: AttributedString) -> [Double] {
        text.runs.compactMap { run in
            String(text[run.range].characters).trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
        }
    }
}

/// Voice activity, as backend/listen.py's Segmenter: an utterance runs from the first loud
/// frame to a pause. The noise floor follows the quiet frames, so a noisy room needs louder
/// speech; an utterance ends after `pause` seconds of quiet or is cut at `longest`;
/// anything shorter than `shortest` is a noise.
struct Segmenter {
    enum Event {
        case speech(at: Double)
        case silence(at: Double, kept: Bool)
        case utterance(start: Double, samples: [Float])
    }

    let rate: Double
    var pause = 0.7, longest = 12.0, shortest = 0.4
    private var floor: Float = 0.004
    private var position = 0
    private var pending: [Float] = []
    private var utterance: [[Float]] = []
    private var start = 0
    private var quiet = 0
    /// The last few quiet frames: an utterance starts a little before its first loud frame,
    /// so a soft first consonant isn't cut off.
    private var before: [[Float]] = []
    private let preroll = 10  // 0.3 s
    private var frame: Int { Int(rate * 0.03) }  // 30 ms

    init(rate: Double) {
        self.rate = rate
    }

    mutating func feed(_ audio: [Float]) -> [Event] {
        pending += audio
        var out: [Event] = []
        while pending.count >= frame {
            let piece = Array(pending.prefix(frame))
            pending.removeFirst(frame)
            out += step(piece)
        }
        return out
    }

    private mutating func step(_ piece: [Float]) -> [Event] {
        let rms = VoicePrint.rms(piece)
        let loud = rms > max(floor * 3, 0.008)
        if !loud { floor = 0.95 * floor + 0.05 * rms }
        let here = position
        position += piece.count
        if utterance.isEmpty {
            guard loud else {
                before = Array((before + [piece]).suffix(preroll))
                return []
            }
            start = here - before.count * frame
            quiet = 0
            utterance = before + [piece]
            before = []
            return [.speech(at: Double(here) / rate)]
        }
        utterance.append(piece)
        quiet = loud ? 0 : quiet + 1
        let length = Double(utterance.count * frame) / rate
        if Double(quiet * frame) / rate >= pause || length >= longest { return close() }
        return []
    }

    mutating func flush() -> [Event] { utterance.isEmpty ? [] : close() }

    private mutating func close() -> [Event] {
        let frames = utterance.count - quiet > 0 ? Array(utterance.prefix(utterance.count - quiet)) : utterance
        let audio = frames.flatMap { $0 }
        let begin = Double(start) / rate
        utterance = []
        quiet = 0
        let kept = Double(audio.count) / rate >= shortest
        var out: [Event] = [.silence(at: begin + Double(audio.count) / rate, kept: kept)]
        if kept { out.append(.utterance(start: begin, samples: audio)) }
        return out
    }
}
