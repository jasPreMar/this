import SwiftUI
import Charts

/// Recursively renders a UINode tree into native SwiftUI views
struct NodeRenderer: View {
    let node: UINode

    var body: some View {
        switch node {
        case .vstack(let n):
            vstackView(n)
        case .hstack(let n):
            hstackView(n)
        case .zstack(let n):
            zstackView(n)
        case .text(let n):
            textView(n)
        case .stat(let n):
            statView(n)
        case .chart(let n):
            chartView(n)
        case .list(let n):
            listView(n)
        case .table(let n):
            tableView(n)
        case .divider:
            Divider()
        case .spacer:
            Spacer()
        case .image(let n):
            imageView(n)
        case .badge(let n):
            badgeView(n)
        case .card(let n):
            cardView(n)
        case .progress(let n):
            progressView(n)
        }
    }

    // MARK: - Layout Views

    @ViewBuilder
    private func vstackView(_ n: VStackNode) -> some View {
        let alignment: HorizontalAlignment = switch n.alignment {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
        VStack(alignment: alignment, spacing: n.spacing ?? 8) {
            ForEach(n.children) { child in
                NodeRenderer(node: child)
            }
        }
    }

    @ViewBuilder
    private func hstackView(_ n: HStackNode) -> some View {
        let alignment: VerticalAlignment = switch n.alignment {
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
        HStack(alignment: alignment, spacing: n.spacing ?? 8) {
            ForEach(n.children) { child in
                NodeRenderer(node: child)
            }
        }
    }

    @ViewBuilder
    private func zstackView(_ n: ZStackNode) -> some View {
        ZStack {
            ForEach(n.children) { child in
                NodeRenderer(node: child)
            }
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private func textView(_ n: TextNode) -> some View {
        let font: Font = switch n.style {
        case "largeTitle": .largeTitle
        case "title": .title
        case "title2": .title2
        case "title3": .title3
        case "headline": .headline
        case "subheadline": .subheadline
        case "caption": .caption
        case "caption2": .caption2
        case "footnote": .footnote
        default: .body
        }

        let weight: Font.Weight = switch n.weight {
        case "bold": .bold
        case "semibold": .semibold
        case "medium": .medium
        case "light": .light
        case "heavy": .heavy
        case "black": .black
        case "thin": .thin
        case "ultraLight": .ultraLight
        default: .regular
        }

        Text(n.content)
            .font(font.weight(weight))
            .foregroundStyle(n.color?.resolvedColor ?? .primary)
            .lineLimit(n.maxLines)
    }

    @ViewBuilder
    private func statView(_ n: StatNode) -> some View {
        let isLarge = n.size == "large"
        VStack(spacing: 4) {
            if let icon = n.icon {
                Image(systemName: icon)
                    .font(isLarge ? .title2 : .body)
                    .foregroundStyle(n.color?.resolvedColor ?? .accentColor)
            }
            Text(n.label)
                .font(isLarge ? .subheadline : .caption)
                .foregroundStyle(.secondary)
            Text(n.value)
                .font(isLarge ? .title.bold() : .headline)
                .foregroundStyle(n.color?.resolvedColor ?? .primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func imageView(_ n: ImageNode) -> some View {
        let size: Font = switch n.size {
        case "small": .body
        case "large": .largeTitle
        case "xlarge": .system(size: 48)
        default: .title2
        }
        Image(systemName: n.systemName)
            .font(size)
            .foregroundStyle(n.color?.resolvedColor ?? .accentColor)
    }

    @ViewBuilder
    private func badgeView(_ n: BadgeNode) -> some View {
        Text(n.text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(n.color?.resolvedColor.opacity(0.15) ?? Color.accentColor.opacity(0.15))
            .foregroundStyle(n.color?.resolvedColor ?? .accentColor)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func cardView(_ n: CardNode) -> some View {
        NodeRenderer(node: n.child)
            .padding(n.padding ?? 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(n.color?.resolvedColor.opacity(0.08) ?? Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: n.cornerRadius ?? 12))
    }

    @ViewBuilder
    private func progressView(_ n: ProgressNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = n.label {
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(n.value / n.total * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(n.color?.resolvedColor ?? .accentColor)
                        .frame(width: geo.size.width * min(n.value / n.total, 1.0))
                }
            }
            .frame(height: 8)
        }
    }

    // MARK: - Chart View

    @ViewBuilder
    private func chartView(_ n: ChartNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = n.title {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Chart(n.data) { point in
                switch n.variant {
                case "pie":
                    SectorMark(
                        angle: .value(point.label, point.value)
                    )
                    .foregroundStyle(by: .value("Category", point.label))
                case "line":
                    LineMark(
                        x: .value("Category", point.label),
                        y: .value("Amount", point.value)
                    )
                    .foregroundStyle(point.color?.resolvedColor ?? .accentColor)
                    .symbol(Circle())
                    PointMark(
                        x: .value("Category", point.label),
                        y: .value("Amount", point.value)
                    )
                    .foregroundStyle(point.color?.resolvedColor ?? .accentColor)
                default: // "bar" and any other
                    BarMark(
                        x: .value("Category", point.label),
                        y: .value("Amount", point.value)
                    )
                    .foregroundStyle(point.color?.resolvedColor ?? .accentColor)
                    .cornerRadius(4)
                }
            }
            .frame(height: 200)
        }
    }

    // MARK: - List View

    @ViewBuilder
    private func listView(_ n: ListNode) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(n.items.enumerated()), id: \.offset) { index, item in
                NodeRenderer(node: item)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
                if index < n.items.count - 1 {
                    Divider()
                }
            }
        }
    }

    // MARK: - Table View

    @ViewBuilder
    private func tableView(_ n: TableNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = n.title {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            // Header row
            if !n.headers.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(n.headers.enumerated()), id: \.offset) { _, header in
                        Text(header)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Divider()
            }
            // Data rows
            ForEach(Array(n.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                if rowIndex < n.rows.count - 1 {
                    Divider()
                }
            }
        }
    }
}
