import SwiftUI

/// The microphone, at the bottom within reach of the thumb, and everything about the
/// listening around it: the button itself shows the state (off; connecting; listening, its
/// ring breathing with the sound; hearing someone; working out what was said), the level
/// to its left, how much has come in to its right, and one line of plain words below.
struct TalkDock: View {
    let session: TalkSession

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Group {
                    if session.listening {
                        LevelMeter(level: session.level, color: tint)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                MicButton(session: session, tint: tint)
                    .padding(.horizontal, 22)
                VStack(alignment: .leading, spacing: 1) {
                    if session.wordsHeard > 0 {
                        Text("\(session.wordsHeard) words")
                        Text("\(session.connectionCount) links")
                    }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("talkWordCount")
            }
            .frame(height: 74)
            Text(message)
                .font(.caption.bold())
                .foregroundStyle(session.phase == .off ? .secondary : .primary)
                .lineLimit(1)
                .accessibilityIdentifier("talkStatus")
        }
        .foregroundStyle(.white)
        .padding(.top, 10).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.09, green: 0.1, blue: 0.15))
        .animation(.snappy, value: session.phase)
    }

    private var language: String? {
        guard let lang = session.lastLanguage else { return nil }
        let name = TalkCaption.name(lang)
        return session.lastLanguageKnown ? name : "\(name)?"
    }

    private var message: String {
        switch session.phase {
        case .off:
            return session.isEmpty ? "Tap to listen" : "Paused — tap to listen again"
        case .connecting:
            return "Connecting… the first time takes up to a minute"
        case .listening:
            return ["Listening", language].compactMap { $0 }.joined(separator: " · ")
        case .hearing:
            return "Hearing someone…"
        case .understanding:
            return "Working out who said what…"
        }
    }

    private var tint: Color {
        switch session.phase {
        case .off: return .gray
        case .connecting, .understanding: return .orange
        case .listening: return .red
        case .hearing: return .green
        }
    }
}

/// The big round microphone: grey when off, red while listening with a ring that swells
/// with the sound, green while someone talks, a turning arc while connecting or working.
struct MicButton: View {
    let session: TalkSession
    let tint: Color
    @State private var turning = false

    var body: some View {
        Button {
            if session.listening { session.stop() } else { Task { await session.start() } }
        } label: {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.45), lineWidth: 4)
                    .scaleEffect(session.listening ? 1.08 + CGFloat(session.level) * 0.3 : 1)
                    .opacity(session.listening ? 1 : 0)
                    .animation(.easeOut(duration: 0.1), value: session.level)
                if session.phase == .connecting || session.phase == .understanding {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .scaleEffect(1.08)
                        .rotationEffect(.degrees(turning ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
                        .onAppear { turning = true }
                        .onDisappear { turning = false }
                }
                Circle()
                    .fill(session.listening ? tint : Color.white.opacity(0.18))
                Image(systemName: session.listening ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor, isActive: session.talking)
            }
            .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.listening ? "Stop listening" : "Listen")
        .accessibilityIdentifier("listen")
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
