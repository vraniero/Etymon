import SwiftUI

/// What the listening is doing, always in view while Talk listens: connecting, listening
/// (with the microphone's level, so it's plain that it picks up sound), hearing someone,
/// working out what was said. Then how many words have come in, and how many grew a tree.
struct TalkStatus: View {
    let session: TalkSession
    /// One short line, for the folded controls.
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(compact ? shortMessage : message).font(.caption.bold()).lineLimit(compact ? 1 : 2)
            if !compact { Spacer(minLength: 4) }
            if compact, session.wordsHeard > 0 {
                Text("\(session.wordsHeard)/\(session.wordsFound)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            } else if session.wordsHeard > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(session.wordsHeard) words · \(session.wordsFound) found")
                    if session.listening { Text("\(session.wordsPerMinute)/min") }
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("talkWordCount")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.7), lineWidth: 1))
        .animation(.snappy, value: session.phase)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("talkStatus")
    }

    private var message: String {
        switch session.phase {
        case .off:
            return session.isEmpty ? "Microphone off — tap it to listen" : "Microphone off"
        case .connecting:
            return "Connecting… the first time, the speech models take up to a minute to load"
        case .listening:
            return session.level > 0.25 ? "Listening — speak a little longer…" : "Listening — no one speaking"
        case .hearing:
            return "Hearing someone…"
        case .understanding:
            return "Working out who said what…"
        }
    }

    private var shortMessage: String {
        switch session.phase {
        case .off: return "Mic off"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .hearing: return "Hearing…"
        case .understanding: return "Understanding…"
        }
    }

    private var tint: Color {
        switch session.phase {
        case .off: return .gray
        case .connecting, .understanding: return .orange
        case .listening: return .blue
        case .hearing: return .green
        }
    }

    @ViewBuilder private var indicator: some View {
        switch session.phase {
        case .off:
            Image(systemName: "mic.slash").foregroundStyle(.secondary)
        case .connecting, .understanding:
            ProgressView().controlSize(.small).tint(.orange)
        case .listening, .hearing:
            LevelMeter(level: session.level, color: tint)
        }
    }
}

/// Five bars rising with the microphone's loudness.
struct LevelMeter: View {
    let level: Float
    var color: Color = .green

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5) { i in
                let lit = level > Float(i) / 5 + 0.04
                Capsule()
                    .fill(lit ? color : .white.opacity(0.25))
                    .frame(width: 3, height: 5 + CGFloat(i) * 3)
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

/// The latest utterance: who said it, in which language (or that the language wasn't one
/// Etymon knows), and the words said, each marked by what became of it: in the speaker's
/// colour when it grew a tree, dotted while it's looked up, dim when the dictionary
/// doesn't have it. Short, common words stay plain: they aren't looked up.
struct TalkCaption: View {
    let caption: TalkSession.Caption

    var body: some View {
        let color = Color(NetworkScene.speakerColor(caption.speaker))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Speaker \(caption.speaker)").bold().foregroundStyle(color)
                language
                Spacer(minLength: 0)
                let found = caption.words.values.filter { $0 == .found }.count
                if !caption.words.isEmpty {
                    Text("\(found)/\(caption.words.count) found")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Text(Self.marked(caption, color: color))
                .font(.callout).lineLimit(3)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var language: some View {
        if let lang = caption.lang {
            Label(Self.name(lang), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if let detected = caption.detected {
            Label("\(Self.name(detected)) — not a language Etymon knows",
                  systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Label("Language not recognized", systemImage: "questionmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    static func name(_ code: String) -> String {
        if code == "sh" { return "Serbo-Croatian" }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    static func marked(_ caption: TalkSession.Caption, color: Color) -> AttributedString {
        var text = AttributedString(caption.text)
        text.foregroundColor = .white.opacity(0.65)
        for token in WordExtractor.tokens(in: caption.text) {
            guard let state = caption.words[token.word.lowercased()],
                  let lower = AttributedString.Index(token.range.lowerBound, within: text),
                  let upper = AttributedString.Index(token.range.upperBound, within: text) else { continue }
            switch state {
            case .found:
                text[lower..<upper].foregroundColor = color
                text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            case .looking:
                text[lower..<upper].foregroundColor = .white
                text[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot)
            case .missing:
                text[lower..<upper].foregroundColor = .white.opacity(0.4)
            }
        }
        return text
    }
}
