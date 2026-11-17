import SwiftUI

/// Settings › Languages: which of the dictionary's languages are on the phone, and how big
/// each is to download. Any can be added or removed; the core can't.
struct LanguagesView: View {
    @State private var packs = LanguagePacks.shared

    var body: some View {
        List {
            Section {
                row(LanguagePacks.core, title: "Core", detail: "Latin, Greek, Proto-Indo-European "
                    + "and the other old languages every language goes back to.", removable: false)
            }
            Section {
                ForEach(WordExtractor.languages.sorted { LanguagePacks.name(of: $0) < LanguagePacks.name(of: $1) },
                        id: \.self) { language in
                    row(LanguagePacks.pack(for: language), title: LanguagePacks.name(of: language))
                }
                row(LanguagePacks.rareEnglish, title: "More English",
                    detail: "Rarer English words, past the common ones.")
            } header: {
                Text("Languages")
            } footer: {
                Text("Each language is downloaded once and then works offline. A language the "
                     + "app reads that isn't here yet is offered as it comes up.")
            }
        }
        .navigationTitle("Languages")
    }

    private func row(_ id: String, title: String, detail: String? = nil,
                     removable: Bool = true) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if case .failed(let message) = packs.state(of: id) {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            control(id, removable: removable)
        }
        .accessibilityIdentifier("pack-\(id)")
    }

    @ViewBuilder
    private func control(_ id: String, removable: Bool) -> some View {
        switch packs.state(of: id) {
        case .downloading(let done):
            ProgressView(value: done).frame(width: 60)
        case .installing:
            ProgressView()
        case .installed:
            if removable {
                Menu {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        Task { await packs.remove(id) }
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .accessibilityLabel("Downloaded")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
            }
        case .absent, .failed:
            Button {
                Task { await packs.install(id) }
            } label: {
                Label(size(id), systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon).font(.callout).monospacedDigit()
            }
            .buttonStyle(.borderless)
        }
    }

    private func size(_ id: String) -> String {
        guard let bytes = packs.sizes[id] else { return "Get" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// "This looks like Polish: download it?" — shown when the app reads a language that
/// isn't on the phone yet.
struct LanguageOfferBanner: View {
    @State private var packs = LanguagePacks.shared

    var body: some View {
        if let language = packs.offer {
            let name = LanguagePacks.name(of: language)
            HStack(spacing: 12) {
                Image(systemName: "character.book.closed").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This looks like \(name)").font(.subheadline.weight(.semibold))
                    Text(sizeLine(language)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Not now") { packs.declineOffer() }
                    .buttonStyle(.borderless).font(.callout)
                Button("Download") { packs.acceptOffer() }
                    .buttonStyle(.borderedProminent).font(.callout)
                    .accessibilityIdentifier("downloadLanguage")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func sizeLine(_ language: String) -> String {
        let bytes = packs.sizes[LanguagePacks.pack(for: language)]
        let size = bytes.map { " (" + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + ")" } ?? ""
        return "Download its words\(size) to find their roots."
    }
}
