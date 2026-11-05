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
    /// The languages the backend knows, by Wiktionary code (Serbo-Croatian is one, "sh").
    static let languages = ["it", "en", "es", "fr", "de",
                            "ru", "uk", "be", "bg", "mk",
                            "sh", "pl", "cs", "sk", "sl",
                            "ro", "hu", "et", "lt", "lv"]
    /// System codes for the same languages where they differ (NaturalLanguage, Vision).
    static let systemCodes: [String: [String]] = ["sh": ["hr", "sr", "bs"]]
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
        // ru, uk, be
        "что", "это", "как", "для", "или", "его", "она", "они", "все", "был", "так", "уже",
        "при", "без", "над", "под", "про", "где", "кто", "нет", "або", "його", "вона", "вони",
        "від", "але", "які", "яка", "який", "щоб", "яго", "яна", "яны", "што", "гэта",
        // bg, mk, sh (Cyrillic)
        "във", "със", "като", "това", "тази", "този", "които", "кои", "или", "што", "које",
        "који", "која", "али", "као", "ова", "ово",
        // sh, sl (Latin)
        "ili", "koji", "koja", "koje", "što", "kao", "ali", "ova", "ovo", "taj", "bez", "pri",
        "nad", "kod", "kot", "ter", "tudi", "kar", "brez",
        // pl, cs, sk
        "nie", "jest", "się", "dla", "oraz", "lub", "jak", "ale", "przy", "przez", "tak",
        "czy", "jego", "jej", "ich", "który", "która", "które", "też", "już", "není", "jsou",
        "nebo", "při", "přes", "jeho", "její", "jejich", "který", "která", "které", "pre",
        "alebo", "ako", "cez", "ktorý", "ktorá", "ktoré", "aby",
        // hu
        "egy", "és", "nem", "hogy", "azt", "ezt", "volt", "vagy", "csak", "mint", "még", "már",
        // ro
        "și", "sau", "pentru", "este", "sunt", "cel", "cea", "cele", "într", "unei", "unui",
        "lui", "prin", "spre", "fost", "fie",
        // lt, lv, et
        "kad", "yra", "arba", "kaip", "nuo", "iki", "prie", "jis", "jie", "tai", "kuris",
        "kuri", "arī", "pēc", "nav", "tas", "kur", "või", "aga", "nii", "kes", "ning",
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
        recognizer.languageConstraints = languages.flatMap { systemCodes[$0] ?? [$0] }
            .map { NLLanguage($0) }
        recognizer.processString(text)
        guard let (lang, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence > 0.5 else { return nil }
        return code(forSystem: lang.rawValue)
    }

    /// Wiktionary code for a system language code: hr, sr, bs -> sh.
    static func code(forSystem system: String) -> String {
        let base = String(system.prefix { $0 != "-" && $0 != "_" })
        return systemCodes.first { $0.value.contains(base) }?.key ?? base
    }

    /// The supported languages Vision can read at each recognition level, in the order of
    /// `languages` (earlier ones are preferred when text is ambiguous).
    static let accurateLanguages = supportedRecognitionLanguages(.accurate)
    static let fastLanguages = supportedRecognitionLanguages(.fast)

    /// Whether quick recognition can read this text. It knows only a few Latin-script
    /// languages: Cyrillic, or Polish with its ł and ś, needs careful passes even to track.
    static func fastReads(_ text: String) -> Bool {
        if let lang = dominantLanguage(of: text) {
            return fastLanguages.contains { code(forSystem: $0) == lang }
        }
        return text.unicodeScalars.allSatisfy { $0.value < 0x0180 }  // Latin-1 and Extended-A
    }

    static func supportedRecognitionLanguages(_ level: VNRequestTextRecognitionLevel) -> [String] {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = level
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        return languages.flatMap { lang in supported.filter { code(forSystem: $0) == lang }.prefix(1) }
    }

    /// Recognise text and word positions in an image. `fast` trades accuracy for speed,
    /// for re-locating known words between full passes.
    static func recognize(_ handler: VNImageRequestHandler, fast: Bool) throws -> Recognition {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = fast ? fastLanguages : accurateLanguages
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
