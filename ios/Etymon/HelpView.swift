import SwiftUI

/// How to use Etymon: modes, how to read the overlay, Hold/Collect, the other controls.
/// Opened from the ? button in the toolbar. Keep in step with "Using the app" in README.md.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(LocalizedStringKey(
                        "Etymon reads the words around you and shows how they are related: "
                        + "words that descend from a **shared root**, and words that have the "
                        + "**same meaning** in different languages."))
                }

                Section("Modes") {
                    HelpRow(symbol: "camera", title: "Camera",
                            text: "Point the phone at text. The network is drawn over the live video, "
                                + "anchored to the words, and follows them as you move.")
                    HelpRow(symbol: "photo", title: "Photo",
                            text: "Pick a picture with text; the network is drawn over it.")
                    HelpRow(symbol: "keyboard", title: "Type",
                            text: "Type or paste words and press Connect; the network is shown as a graph.")
                }

                Section("Reading the network") {
                    LegendRow(text: "Connected to another word in the scene") {
                        RoundedRectangle(cornerRadius: 5).stroke(Color.yellow, lineWidth: 2.5)
                            .frame(width: 36, height: 20)
                    }
                    LegendRow(text: "Read, but not connected to anything yet") {
                        RoundedRectangle(cornerRadius: 5).stroke(Color.gray, lineWidth: 1)
                            .frame(width: 36, height: 20)
                    }
                    LegendRow(text: "**Shared root**: both words descend from this ancestor, "
                              + "e.g. notte and night from Proto-Indo-European \\*nókʷts. "
                              + "Italic with \\* = reconstructed, never written down.") {
                        Text("*nókʷts").font(.caption.bold()).italic()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 1.0, green: 0.92, blue: 0.62)))
                            .foregroundStyle(.black)
                    }
                    LegendRow(text: "Inside a bubble: the words share the root **and** mean the same.") {
                        Text("= night").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                    LegendRow(text: "**Same meaning** in different languages, without a shared "
                              + "root, e.g. Aperta = Open.") {
                        Text("= open").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green))
                    }
                }

                Section {
                    HelpRow(symbol: "pause.fill", title: "Hold",
                            text: "Shown while the app is collecting. About once a second it reads "
                                + "the frame and adds new words to the scene, up to the limit in Settings "
                                + "(20 by default), then updates the network. With more words in view "
                                + "than that, words still in view keep their place and the largest new "
                                + "words wait for one to leave the frame. Pan across a street and "
                                + "words from different signs build up and connect.\n\n"
                                + "Tap Hold to freeze the scene: no new words are added and the network "
                                + "stays as it is.")
                    HelpRow(symbol: "plus.viewfinder", title: "Collect",
                            text: "Shown while the scene is frozen. The collected words are still "
                                + "tracked: outlines, bubbles and arcs keep following them as you move. "
                                + "Words that leave the frame fade out and come back when you point at "
                                + "them again.\n\nTap Collect to start adding new words again.")
                } header: {
                    Text("Camera: Hold and Collect")
                } footer: {
                    Text("One button, two modes: the label is the action it will take. Hold is "
                         + "useful when you have found an interesting set of words and don't want "
                         + "new text crowding them out.")
                }

                Section {
                    HelpRow(symbol: "cube.transparent", title: "Explore",
                            text: "Leave the picture for the word network behind it. The video stops "
                                + "and the network opens in 3D: the words you saw sit at the bottom, "
                                + "their ancestors rise above them — the older, the higher.")
                    HelpRow(symbol: "hand.draw", title: "Move around",
                            text: "Drag to turn, pinch to zoom, two fingers to move. Press and hold a "
                                + "word, then drag it to put it somewhere else; its links follow.")
                    HelpRow(symbol: "arrow.right.circle", title: "Jump",
                            text: "Tap a word: the camera flies to it and the panel shows what it "
                                + "comes from, what it gave and what means the same. Tap any of those "
                                + "to jump on.")
                    HelpRow(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: "Expand",
                            text: "Bring in the word's own parents and descendants from the "
                                + "dictionary, beyond the scene — Latin pater adds German Pater, "
                                + "English Paternoster, Spanish padrastro… Lineage shows its full "
                                + "ancestry. Back returns to the camera.")
                } header: {
                    Text("Explore in 3D")
                } footer: {
                    Text("Blue: seen in the scene · yellow: ancestors (stronger yellow: shared "
                         + "roots) · grey: brought in by Expand. Yellow lines: descent · orange: "
                         + "borrowing · green: same meaning.")
                }

                Section("Other controls") {
                    HelpRow(symbol: "trash", title: "Clear",
                            text: "Clear the scene and start fresh.")
                    HelpRow(symbol: "point.3.connected.trianglepath.dotted", title: "Graph",
                            text: "The same network as a diagram (camera and photo).")
                    HelpRow(symbol: "square.3.layers.3d", title: "Both · Roots · Meanings",
                            text: "Choose what the network shows: shared roots (etymology), same "
                                + "meanings (translations), or both side by side. Above the graph, and "
                                + "in the menu at the bottom right of the camera and photo views; "
                                + "the overlay follows the same choice.")
                    HelpRow(symbol: "map", title: "Tree · Map",
                            text: "Show the network as a tree, or on a world map: each word sits where "
                                + "its language was spoken and arcs run from ancestor to descendant, "
                                + "so you can follow a word from its homeland to the words you see. "
                                + "Proto-language homelands are scholarly estimates.")
                    HelpRow(symbol: "figure.walk", title: "Follow",
                            text: "On the map, pick a word and travel its line back in time, from "
                                + "the word you saw to its oldest known root: step with ‹ ›, or press "
                                + "play. The way travelled is drawn bold, the way ahead faint.")
                    HelpRow(symbol: "arrow.up.and.down.text.horizontal", title: "Full paths",
                            text: "In the graph, show every step of each chain instead of just the "
                                + "shared ancestor.")
                    HelpRow(symbol: "hand.tap", title: "Tap a bubble",
                            text: "How the two words reach their shared ancestor, step by step, and "
                                + "the deeper line above it to the oldest known root.")
                    HelpRow(symbol: "hand.point.up.left", title: "Tap a word",
                            text: "That word's own lineage.")
                    HelpRow(symbol: "ruler", title: "Search depth",
                            text: "How far back each word's ancestry is searched for shared roots "
                                + "(default 16; each link costs about 1, a jump to a reconstructed "
                                + "root 6). The bar above the graph shows it: the shaded part is how "
                                + "far the search actually got, the orange mark what the deepest "
                                + "connection needed. Change it with − and + there or in Settings.")
                    HelpRow(symbol: "gear", title: "Settings",
                            text: "The backend address (http://localhost:8000 in the simulator, "
                                + "http://<your Mac's address>:8000 on a phone) and the search depth.")
                }

                Section {
                    Text("The status line at the bottom counts the words, shared roots and "
                         + "same-meaning links, and shows the scene's detected language. "
                         + "Supported: English, Italian, Spanish, French, German; Russian, Ukrainian, "
                         + "Belarusian, Bulgarian, Macedonian, Serbo-Croatian; Polish, Czech, "
                         + "Slovak, Slovene; Romanian, Hungarian, Estonian, Lithuanian, Latvian. "
                         + "The camera reads the scripts and accents your iOS version supports.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Etymological data from Wiktionary, CC BY-SA 4.0.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("How it works")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct HelpRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LegendRow<Sample: View>: View {
    let text: LocalizedStringKey
    @ViewBuilder let sample: Sample

    init(text: String, @ViewBuilder sample: () -> Sample) {
        self.text = LocalizedStringKey(text)
        self.sample = sample()
    }

    var body: some View {
        HStack(spacing: 12) {
            sample.frame(width: 72)
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
