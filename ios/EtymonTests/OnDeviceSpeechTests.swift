import AVFoundation
import Speech
import XCTest
@testable import Etymon

/// Talk on the phone, on a recorded conversation (Fixtures/conversation.wav, made with the
/// Mac's voices): Alice in Italian, Daniel in English, Alice again, Anna in German, Daniel
/// again, a second of silence between them.
final class OnDeviceSpeechTests: XCTestCase {
    static let expectedLanguages = ["it", "en", "it", "de", "en"]
    static let expectedSpeakers = ["P1", "P2", "P1", "P3", "P2"]

    /// In the test bundle (on a phone), or next to this file (the simulator sees the Mac).
    private var recording: URL {
        Bundle(for: Self.self).url(forResource: "conversation", withExtension: "wav")
            ?? URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/conversation.wav")
    }

    private func buffers() throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: recording)
        var out: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: buffer)
            out.append(buffer)
        }
        return out
    }

    func testCutsTheConversationAndTellsTheVoicesApart() throws {
        var segmenter = Segmenter(rate: 16_000)
        var utterances: [[Float]] = []
        for buffer in try buffers() {
            for case .utterance(_, let samples) in segmenter.feed(OnDeviceSpeech.samples(buffer)) {
                utterances.append(samples)
            }
        }
        for case .utterance(_, let samples) in segmenter.flush() { utterances.append(samples) }
        XCTAssertEqual(utterances.count, 5)

        let prints = utterances.compactMap { VoicePrint.embedding($0) }
        XCTAssertEqual(prints.count, 5)
        for (i, a) in prints.enumerated() {
            print("voice \(i + 1):", prints.map { String(format: "%6.1f", VoicePrint.distance(a, $0)) }.joined(separator: " "))
        }
        let voices = Voices()
        XCTAssertEqual(prints.map { voices.assign($0).0.id }, Self.expectedSpeakers)
    }

    /// The whole of Talk's listening: needs the phone's speech recognition (and the
    /// dictionary, to tell languages apart best). Skipped where they're missing.
    func testUnderstandsWhoSaidWhatInWhichLanguage() async throws {
        let speech = OnDeviceSpeech()
        let database = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../pipeline/data/etymon-mobile.sqlite").standardized
        speech.dictionary = LocalBackend.shared ?? (try? LocalBackend(url: database))
        let languages: [String]
        do {
            languages = try await speech.prepare(languages: ["it", "en", "de"])
        } catch {
            throw XCTSkip("no on-device speech recognition here: \(error.localizedDescription)")
        }
        let lock = NSLock()
        var heard: [ConversationStream.Utterance] = []
        speech.onCandidates = { candidates in
            print("--")
            for c in candidates {
                print(String(format: "  %@ %.2f conf %.2f reads %.2f dict %.2f  %@", c.code, c.score,
                             c.parts["conf"] ?? 0, c.parts["reads"] ?? 0, c.parts["dict"] ?? 0, c.text))
            }
        }
        speech.emit = { event in
            if case .utterance(let u) = event { lock.withLock { heard.append(u) } }
        }
        for buffer in try buffers() { speech.feed(buffer) }
        await speech.finish()
        print("listening for", languages)
        for u in heard { print("\(u.persona) [\(u.lang ?? "--")] \(u.text)") }
        XCTAssertEqual(heard.count, Self.expectedLanguages.count)
        // a language whose model this device can't get can't be recognised: not checked
        for (u, expected) in zip(heard, Self.expectedLanguages) where languages.contains(expected) {
            XCTAssertEqual(u.lang, expected, u.text)
        }
        XCTAssertEqual(heard.map(\.persona), Self.expectedSpeakers)
    }

    /// Auto: listening only for Italian and English, the German sentence is found anyway,
    /// and German is listened for from then on.
    func testAutoFindsAnotherLanguage() async throws {
        let speech = OnDeviceSpeech()
        speech.dictionary = LocalBackend.shared
        speech.autoDetect = true
        do {
            try await speech.prepare(languages: ["it", "en"])
        } catch {
            throw XCTSkip("no on-device speech recognition here: \(error.localizedDescription)")
        }
        let saved = UserDefaults.standard.stringArray(forKey: OnDeviceSpeech.languagesKey)
        defer { UserDefaults.standard.set(saved, forKey: OnDeviceSpeech.languagesKey) }
        let lock = NSLock()
        var heard: [ConversationStream.Utterance] = []
        var added: [String] = []
        speech.onCandidates = { candidates in
            print("--")
            for c in candidates { print(String(format: "  %@ %.2f  %@", c.code, c.score, c.text)) }
        }
        speech.emit = { event in
            lock.withLock {
                switch event {
                case .utterance(let u): heard.append(u)
                case .languages(_, let code): added.append(code)
                default: break
                }
            }
        }
        for buffer in try buffers() { speech.feed(buffer) }
        await speech.finish()
        for u in heard { print("\(u.persona) [\(u.lang ?? "--")] \(u.text)") }
        XCTAssertEqual(heard.map { $0.lang ?? "" }, Self.expectedLanguages)
        XCTAssertEqual(added, ["de"])
    }

    /// What the phone says about each language's speech model (printed; never fails).
    func testSpeechModelsReport() async throws {
        print("max reserved:", AssetInventory.maximumReservedLocales,
              "reserved:", await AssetInventory.reservedLocales.map(\.identifier))
        for code in ["it", "en", "de"] {
            guard let locale = await OnDeviceSpeech.locale(for: code) else {
                print(code, "no locale"); continue
            }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                      attributeOptions: [.audioTimeRange])
            var reserved = "?"
            do { reserved = String(try await AssetInventory.reserve(locale: locale)) } catch { reserved = "error \(error)" }
            let before = await AssetInventory.status(forModules: [t])
            var install = "none needed"
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                    try await request.downloadAndInstall()
                    install = "installed"
                }
            } catch { install = "error \(error)" }
            let after = await AssetInventory.status(forModules: [t])
            print("\(code) \(locale.identifier): reserve \(reserved), \(before) -> \(install) -> \(after)")
        }
    }
}
