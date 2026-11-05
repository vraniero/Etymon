import SwiftUI

/// The 2D network, as a tree or on a world map (GeoMapView). Each group of words that share ancestry is drawn as its own block:
/// the scene words at the bottom, their meeting points (highlighted) above, lines of
/// descent between them. Words with no connection sit in a row at the end. Tapping a
/// node opens its story.
struct NetworkView: View {
    let response: SceneResponse
    var compact = true
    var onSelect: (GraphLayout.Key) -> Void
    @AppStorage(NetworkStyle.storageKey) private var style: NetworkStyle = .tree

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $style) {
                ForEach(NetworkStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 4)
            .accessibilityIdentifier("networkStyle")
            switch style {
            case .tree: tree
            case .map:
                if let search = response.search { SearchDepthBar(search: search).padding(.bottom, 6) }
                GeoMapView(response: response, onSelect: onSelect)
            }
        }
    }

    @ViewBuilder private var tree: some View {
        let clusters = GraphLayout.clusters(response)
        let connected = Set(clusters.joined())
        let loose = response.words.indices.filter { !connected.contains($0) }
        ScrollView {
            VStack(spacing: 8) {
                if let search = response.search {
                    SearchDepthBar(search: search)
                }
                ForEach(clusters, id: \.self) { cluster in
                    ClusterGraph(layout: GraphLayout(response, compact: compact, only: Set(cluster)),
                                 response: response,
                                 semantic: response.semanticLinks.filter { cluster.contains($0.a) },
                                 onSelect: onSelect)
                    Divider().padding(.horizontal, 40)
                }
                if !loose.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(clusters.isEmpty ? "No connections found yet" : "Not connected")
                            .font(.caption).foregroundStyle(.secondary)
                        FlowLayout(spacing: 8) {
                            ForEach(loose, id: \.self) { i in
                                WordChip(word: response.words[i], isMeeting: false)
                                    .onTapGesture { onSelect(.word(i)) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// One cluster, drawn at full size; scrolls sideways if wider than the screen.
private struct ClusterGraph: View {
    let layout: GraphLayout
    let response: SceneResponse
    let semantic: [SemanticLink]
    var onSelect: (GraphLayout.Key) -> Void

    private let levelHeight: CGFloat = 70
    private let slotWidth: CGFloat = 104
    private let margin = CGSize(width: 60, height: 28)

    var body: some View {
        let below: CGFloat = semantic.isEmpty ? 0 : 44  // room for the meaning arcs
        let size = CGSize(width: layout.width * slotWidth + margin.width * 2,
                          height: CGFloat(layout.maxLevel) * levelHeight + margin.height * 2 + below)
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for link in layout.links {
                        guard let a = layout.items[link.from], let b = layout.items[link.to] else {
                            continue
                        }
                        let p = point(a, in: size), q = point(b, in: size)
                        var path = Path()
                        path.move(to: p)
                        path.addCurve(to: q, control1: CGPoint(x: p.x, y: (p.y + q.y) / 2),
                                      control2: CGPoint(x: q.x, y: (p.y + q.y) / 2))
                        context.stroke(path, with: .color(color(for: link.kind).opacity(0.8)),
                                       style: StrokeStyle(lineWidth: 2,
                                                          dash: link.kind == "borrowed" ? [5, 4] : []))
                    }
                    // same meaning: dashed green arcs under the two words
                    for link in semantic {
                        guard let a = layout.items[.word(link.a)], let b = layout.items[.word(link.b)] else {
                            continue
                        }
                        let p = point(a, in: size, below: below), q = point(b, in: size, below: below)
                        var path = Path()
                        path.move(to: CGPoint(x: p.x, y: p.y + 20))
                        path.addQuadCurve(to: CGPoint(x: q.x, y: q.y + 20),
                                          control: CGPoint(x: (p.x + q.x) / 2, y: p.y + 20 + below))
                        context.stroke(path, with: .color(.green),
                                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
                ForEach(Array(layout.items.values)) { item in
                    NodeLabel(item: item, response: response)
                        .position(point(item, in: size, below: below))
                        .onTapGesture { onSelect(item.key) }
                }
                ForEach(semantic) { link in
                    if let a = layout.items[.word(link.a)], let b = layout.items[.word(link.b)] {
                        let p = point(a, in: size, below: below), q = point(b, in: size, below: below)
                        Text("= \(link.meaning)")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green))
                            .position(x: (p.x + q.x) / 2, y: p.y + 20 + below * 0.55)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .containerRelativeFrame(.horizontal) { length, _ in max(length, size.width) }
        }
    }

    private func point(_ item: GraphLayout.Item, in size: CGSize, below: CGFloat = 0) -> CGPoint {
        CGPoint(x: margin.width + item.x * slotWidth,
                y: size.height - margin.height - below - CGFloat(item.level) * levelHeight)
    }
}

/// How deep the search behind this network went: the depth asked for, how far the climbs
/// actually got (they stop early when a word's recorded ancestry runs out), and what the
/// deepest connection needed. The stepper changes the depth and searches again.
struct SearchDepthBar: View {
    let search: SearchInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                SearchDepthStepper(compact: true).font(.caption).fixedSize()
            }
            GeometryReader { geo in
                let w = geo.size.width, limit = max(search.maxCost, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.teal.opacity(0.45))
                        .frame(width: w * min(search.reached / limit, 1))
                    if search.depth > 0 {
                        Rectangle().fill(Color.orange).frame(width: 3, height: 12)
                            .offset(x: w * min(search.depth / limit, 1) - 1.5)
                    }
                }
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel(summary)
        }
        .padding(.horizontal).padding(.top, 4)
        .accessibilityIdentifier("searchDepthBar")
    }

    private var summary: String {
        let limit = search.maxCost.formatted(), reached = search.reached.formatted()
        let deepest = search.depth > 0 ? " · deepest connection \(search.depth.formatted())" : ""
        return "Searched \(reached) of \(limit)\(deepest)"
    }
}

func color(for kind: String?) -> Color {
    switch kind {
    case "inherited": return .blue
    case "borrowed", "learned", "calque", "semantic_loan": return .orange
    case "component": return .purple
    case "root": return .gray
    default: return .teal
    }
}

private let meetingFill = Color(red: 1.0, green: 0.92, blue: 0.62)
private let wordFill = Color(red: 0.84, green: 0.91, blue: 1.0)
/// Text on the fixed light fills (yellow, light blue) stays dark in dark mode too.
private let ink = Color.black
private let inkSecondary = Color.black.opacity(0.6)

struct WordChip: View {
    let word: SceneWord
    let isMeeting: Bool

    var body: some View {
        let known = !word.terms.isEmpty
        VStack(spacing: 1) {
            Text(word.text).font(.headline)
                .foregroundStyle(known ? ink : Color.secondary)
            if let lang = word.lang {
                Text(lang).font(.caption2)
                    .foregroundStyle(known ? inkSecondary : Color.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(!known ? Color(.systemGray5) : isMeeting ? meetingFill : wordFill))
        .overlay(Capsule().stroke(isMeeting ? Color.orange : .clear, lineWidth: 1.5))
    }
}

private struct NodeLabel: View {
    let item: GraphLayout.Item
    let response: SceneResponse

    var body: some View {
        switch item.key {
        case .word(let i):
            WordChip(word: response.words[i], isMeeting: item.isMeeting)
        case .term(let id):
            let node = response.node(id)
            VStack(spacing: 1) {
                Text(node?.word ?? "?")
                    .font(item.isMeeting ? .subheadline.bold() : .caption)
                    .italic(node?.reconstructed ?? false)
                    .foregroundStyle(item.isMeeting ? ink : Color.primary)
                Text(node?.language ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(item.isMeeting ? inkSecondary : Color.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: 100)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(item.isMeeting ? meetingFill : Color(.secondarySystemBackground)))
        }
    }
}

/// Wraps children onto new lines when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
