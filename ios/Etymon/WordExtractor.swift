import CoreGraphics
import Foundation
import NaturalLanguage
import Vision

/// A word found in an image and where it is: normalized to the upright image,
/// origin top-left (0...1 on both axes).
struct SeenWord: Hashable {
    let text: String
    let box: CGRect
    var key: String { text.lowercased() }
}

/// What one recognition pass found: all the text (for language detection and new
/// words) and each candidate word with its position (for the overlay).
struct Recognition {
    var text = ""
    var words: [SeenWord] = []
}

/// Turns recognised text into the candidate words of a scene.
enum WordExtractor {
    static let languages = ["it", "en", "es", "fr", "de"]
    static let minLength = 3

    /// Function words connect to almost everything through PIE and only add noise.
    static let stopwords: Set<String> = [
        // en
        "the", "and", "for", "with", "from", "this", "that", "are", "was", "you", "your", "our",
        "not", "but", "all", "any", "can", "has", "have", "will", "into", "out", "off", "per",
        // it
        "il", "lo", "la", "gli", "le", "di", "da", "del", "della", "dei", "delle", "degli",
        "che", "per", "con", "non", "una", "uno", "sono", "nel", "nella", "alla", "allo", "sul",
        // es
        "el", "los", "las", "del", "con", "por", "para", "una", "uno", "que", "como", "más",
        // fr
        "les", "des", "une", "est", "pour", "dans", "avec", "sur", "pas", "qui", "que", "aux",
        // de
        "der", "die", "das", "und", "den", "dem", "des", "ein", "eine", "einen", "mit", "von",
        "für", "auf", "ist", "nicht", "zu", "im", "am",
    ]

    /// Runs of letters in a string that are worth looking up (apostrophes split: l'eau -> eau).
    static func tokens(in text: String) -> [(word: String, range: Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var i = text.startIndex
        func flush(_ end: String.Index) {
            if let s = start {
                let word = String(text[s..<end])
                if word.count >= minLength && !stopwords.contains(word.lowercased()) {
                    out.append((word, s..<end))
                }
            }
            start = nil
        }
        while i < text.endIndex {
            if text[i].isLetter {
                if start == nil { start = i }
            } else {
                flush(i)
            }
            i = text.index(after: i)
        }
        flush(text.endIndex)
        return out
    }

    /// Words from a block of text, duplicates removed, order of first appearance kept.
    static func words(in text: String) -> [String] {
        var seen = Set<String>()
        return tokens(in: text).map(\.word).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Most likely language of the whole scene, among the supported ones.
    static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage($0) }
        recognizer.processString(text)
        guard let (lang, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence > 0.5 else { return nil }
        return lang.rawValue
    }

    /// Recognise text and word positions in an image. `fast` trades accuracy for speed,
    /// for re-locating known words between full passes.
    static func recognize(_ handler: VNImageRequestHandler, fast: Bool) throws -> Recognition {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = ["it-IT", "en-US", "es-ES", "fr-FR", "de-DE"]
        request.usesLanguageCorrection = !fast
        try handler.perform([request])

        var result = Recognition()
        var lines: [String] = []
        var seen = Set<String>()
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= (fast ? 0.3 : 0.4) else { continue }
            lines.append(candidate.string)
            for (word, range) in tokens(in: candidate.string) {
                guard seen.insert(word.lowercased()).inserted,
                      let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                // Vision: origin bottom-left; overlay: origin top-left
                result.words.append(SeenWord(text: word, box: CGRect(
                    x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)))
            }
        }
        result.text = lines.joined(separator: "\n")
        return result
    }

    static func recognize(in image: CGImage, orientation: CGImagePropertyOrientation = .up,
                          fast: Bool = false) throws -> Recognition {
        try recognize(VNImageRequestHandler(cgImage: image, orientation: orientation), fast: fast)
    }

    static func recognize(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                          fast: Bool) throws -> Recognition {
        try recognize(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation),
                      fast: fast)
    }
}
