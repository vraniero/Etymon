import CoreGraphics
import Foundation
import NaturalLanguage
import Vision

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

    /// Words from a block of text: letters only, split at apostrophes (l'eau -> eau),
    /// stopwords and very short tokens dropped, order of first appearance kept.
    static func words(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let tokens = text.components(separatedBy: CharacterSet.letters.inverted)
        for token in tokens where token.count >= minLength {
            let key = token.lowercased()
            if stopwords.contains(key) || seen.contains(key) { continue }
            seen.insert(key)
            out.append(token)
        }
        return out
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

    /// Recognise text in an image (a camera frame or a photo).
    static func recognizeText(in image: CGImage,
                              orientation: CGImagePropertyOrientation = .up,
                              fast: Bool = false) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = ["it-IT", "en-US", "es-ES", "fr-FR", "de-DE"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return lines(from: request.results)
    }

    static func recognizeText(in pixelBuffer: CVPixelBuffer,
                              orientation: CGImagePropertyOrientation) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["it-IT", "en-US", "es-ES", "fr-FR", "de-DE"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            .perform([request])
        return lines(from: request.results)
    }

    private static func lines(from results: [VNRecognizedTextObservation]?) -> String {
        (results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.4 }
            .map(\.string)
            .joined(separator: "\n")
    }
}
