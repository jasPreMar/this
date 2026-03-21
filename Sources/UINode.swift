import Foundation
import SwiftUI

/// A recursive UI node that the LLM generates to describe arbitrary layouts
indirect enum UINode: Codable, Identifiable {
    case vstack(VStackNode)
    case hstack(HStackNode)
    case zstack(ZStackNode)
    case text(TextNode)
    case stat(StatNode)
    case chart(ChartNode)
    case list(ListNode)
    case table(TableNode)
    case divider(id: String)
    case spacer(id: String)
    case image(ImageNode)
    case badge(BadgeNode)
    case card(CardNode)
    case progress(ProgressNode)

    var id: String {
        switch self {
        case .vstack(let n): return n.id
        case .hstack(let n): return n.id
        case .zstack(let n): return n.id
        case .text(let n): return n.id
        case .stat(let n): return n.id
        case .chart(let n): return n.id
        case .list(let n): return n.id
        case .table(let n): return n.id
        case .divider(let id): return id
        case .spacer(let id): return id
        case .image(let n): return n.id
        case .badge(let n): return n.id
        case .card(let n): return n.id
        case .progress(let n): return n.id
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "vstack":
            self = .vstack(try VStackNode(from: decoder))
        case "hstack":
            self = .hstack(try HStackNode(from: decoder))
        case "zstack":
            self = .zstack(try ZStackNode(from: decoder))
        case "text":
            self = .text(try TextNode(from: decoder))
        case "stat":
            self = .stat(try StatNode(from: decoder))
        case "chart":
            self = .chart(try ChartNode(from: decoder))
        case "list":
            self = .list(try ListNode(from: decoder))
        case "table":
            self = .table(try TableNode(from: decoder))
        case "divider":
            self = .divider(id: UUID().uuidString)
        case "spacer":
            self = .spacer(id: UUID().uuidString)
        case "image":
            self = .image(try ImageNode(from: decoder))
        case "badge":
            self = .badge(try BadgeNode(from: decoder))
        case "card":
            self = .card(try CardNode(from: decoder))
        case "progress":
            self = .progress(try ProgressNode(from: decoder))
        default:
            // Fallback: render as text with the type name
            self = .text(TextNode(content: "Unknown: \(type)", style: "caption", color: "secondary", weight: nil, maxLines: nil))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .vstack(let n):
            try container.encode("vstack", forKey: .type)
            try n.encode(to: encoder)
        case .hstack(let n):
            try container.encode("hstack", forKey: .type)
            try n.encode(to: encoder)
        case .zstack(let n):
            try container.encode("zstack", forKey: .type)
            try n.encode(to: encoder)
        case .text(let n):
            try container.encode("text", forKey: .type)
            try n.encode(to: encoder)
        case .stat(let n):
            try container.encode("stat", forKey: .type)
            try n.encode(to: encoder)
        case .chart(let n):
            try container.encode("chart", forKey: .type)
            try n.encode(to: encoder)
        case .list(let n):
            try container.encode("list", forKey: .type)
            try n.encode(to: encoder)
        case .table(let n):
            try container.encode("table", forKey: .type)
            try n.encode(to: encoder)
        case .divider:
            try container.encode("divider", forKey: .type)
        case .spacer:
            try container.encode("spacer", forKey: .type)
        case .image(let n):
            try container.encode("image", forKey: .type)
            try n.encode(to: encoder)
        case .badge(let n):
            try container.encode("badge", forKey: .type)
            try n.encode(to: encoder)
        case .card(let n):
            try container.encode("card", forKey: .type)
            try n.encode(to: encoder)
        case .progress(let n):
            try container.encode("progress", forKey: .type)
            try n.encode(to: encoder)
        }
    }
}

// MARK: - Fault-Tolerant Child Decoding

/// Decodes an array of UINodes, skipping any that fail to decode instead of failing the whole array.
struct FaultTolerantNodeArray: Codable {
    let nodes: [UINode]
    let errors: [DecodingError]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var nodes: [UINode] = []
        var errors: [DecodingError] = []

        while !container.isAtEnd {
            do {
                let node = try container.decode(UINode.self)
                nodes.append(node)
            } catch let error as DecodingError {
                errors.append(error)
                _ = try? container.decode(AnyCodable.self)
            }
        }

        self.nodes = nodes
        self.errors = errors
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for node in nodes {
            try container.encode(node)
        }
    }
}

/// A type-erased Codable wrapper for skipping invalid JSON elements during fault-tolerant decoding
private struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if let _ = try? container.decode(Bool.self) { return }
        if let _ = try? container.decode(Int.self) { return }
        if let _ = try? container.decode(Double.self) { return }
        if let _ = try? container.decode(String.self) { return }
        if let _ = try? container.decode([AnyCodable].self) { return }
        if let _ = try? container.decode([String: AnyCodable].self) { return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
    }

    func encode(to encoder: Encoder) throws {
        // No-op: used only for decoding
    }
}

// MARK: - Layout Nodes

struct VStackNode: Codable {
    let id: String
    let spacing: CGFloat?
    let alignment: String?
    let children: [UINode]

    init(id: String = UUID().uuidString, spacing: CGFloat? = nil, alignment: String? = nil, children: [UINode]) {
        self.id = id
        self.spacing = spacing
        self.alignment = alignment
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.spacing = try container.decodeIfPresent(CGFloat.self, forKey: .spacing)
        self.alignment = try container.decodeIfPresent(String.self, forKey: .alignment)
        let tolerant = try container.decode(FaultTolerantNodeArray.self, forKey: .children)
        self.children = tolerant.nodes
    }

    enum CodingKeys: String, CodingKey {
        case spacing, alignment, children
    }
}

struct HStackNode: Codable {
    let id: String
    let spacing: CGFloat?
    let alignment: String?
    let children: [UINode]

    init(id: String = UUID().uuidString, spacing: CGFloat? = nil, alignment: String? = nil, children: [UINode]) {
        self.id = id
        self.spacing = spacing
        self.alignment = alignment
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.spacing = try container.decodeIfPresent(CGFloat.self, forKey: .spacing)
        self.alignment = try container.decodeIfPresent(String.self, forKey: .alignment)
        let tolerant = try container.decode(FaultTolerantNodeArray.self, forKey: .children)
        self.children = tolerant.nodes
    }

    enum CodingKeys: String, CodingKey {
        case spacing, alignment, children
    }
}

struct ZStackNode: Codable {
    let id: String
    let alignment: String?
    let children: [UINode]

    init(id: String = UUID().uuidString, alignment: String? = nil, children: [UINode]) {
        self.id = id
        self.alignment = alignment
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.alignment = try container.decodeIfPresent(String.self, forKey: .alignment)
        let tolerant = try container.decode(FaultTolerantNodeArray.self, forKey: .children)
        self.children = tolerant.nodes
    }

    enum CodingKeys: String, CodingKey {
        case alignment, children
    }
}

// MARK: - Content Nodes

struct TextNode: Codable {
    let id: String
    let content: String
    let style: String?
    let color: String?
    let weight: String?
    let maxLines: Int?

    init(content: String, style: String?, color: String?, weight: String?, maxLines: Int?) {
        self.id = UUID().uuidString
        self.content = content
        self.style = style
        self.color = color
        self.weight = weight
        self.maxLines = maxLines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.content = try container.decode(String.self, forKey: .content)
        self.style = try container.decodeIfPresent(String.self, forKey: .style)
        self.color = try container.decodeIfPresent(String.self, forKey: .color)
        self.weight = try container.decodeIfPresent(String.self, forKey: .weight)
        self.maxLines = try container.decodeIfPresent(Int.self, forKey: .maxLines)
    }

    enum CodingKeys: String, CodingKey {
        case content, style, color, weight, maxLines
    }
}

struct StatNode: Codable {
    let id: String
    let label: String
    let value: String
    let color: String?
    let size: String?
    let icon: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.label = try container.decode(String.self, forKey: .label)
        self.value = try container.decode(String.self, forKey: .value)
        self.color = try container.decodeIfPresent(String.self, forKey: .color)
        self.size = try container.decodeIfPresent(String.self, forKey: .size)
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon)
    }

    enum CodingKeys: String, CodingKey {
        case label, value, color, size, icon
    }
}

struct ImageNode: Codable {
    let id: String
    let systemName: String
    let color: String?
    let size: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.systemName = try container.decode(String.self, forKey: .systemName)
        self.color = try container.decodeIfPresent(String.self, forKey: .color)
        self.size = try container.decodeIfPresent(String.self, forKey: .size)
    }

    enum CodingKeys: String, CodingKey {
        case systemName = "system_name"
        case color, size
    }
}

struct BadgeNode: Codable {
    let id: String
    let text: String
    let color: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.text = try container.decode(String.self, forKey: .text)
        self.color = try container.decodeIfPresent(String.self, forKey: .color)
    }

    enum CodingKeys: String, CodingKey {
        case text, color
    }
}

struct CardNode: Codable {
    let id: String
    let color: String?
    let padding: CGFloat?
    let cornerRadius: CGFloat?
    let child: UINode

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.color = try container.decodeIfPresent(String.self, forKey: .color)
        self.padding = try container.decodeIfPresent(CGFloat.self, forKey: .padding)
        self.cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
        self.child = try container.decode(UINode.self, forKey: .child)
    }

    enum CodingKeys: String, CodingKey {
        case color, padding, cornerRadius, child
    }
}

struct ProgressNode: Codable {
    let id: String
    let value: Double
    let total: Double
    let label: String?
    let color: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.value = try container.decode(Double.self, forKey: .value)
        self.total = try container.decodeIfPresent(Double.self, forKey: .total) ?? 1.0
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.color = try container.decodeIfPresent(String.self, forKey: .color)
    }

    enum CodingKeys: String, CodingKey {
        case value, total, label, color
    }
}

// MARK: - Chart Node

struct ChartNode: Codable {
    let id: String
    let variant: String // "bar", "pie", "line"
    let title: String?
    let data: [ChartDataPoint]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.variant = try container.decode(String.self, forKey: .variant)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.data = try container.decode([ChartDataPoint].self, forKey: .data)
    }

    enum CodingKeys: String, CodingKey {
        case variant, title, data
    }
}

struct ChartDataPoint: Codable, Identifiable {
    let id: String
    let label: String
    let value: Double
    let color: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.label = try container.decode(String.self, forKey: .label)
        self.value = try container.decode(Double.self, forKey: .value)
        self.color = try container.decodeIfPresent(String.self, forKey: .color)
    }

    enum CodingKeys: String, CodingKey {
        case label, value, color
    }
}

// MARK: - List Node

struct ListNode: Codable {
    let id: String
    let items: [UINode]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        let tolerant = try container.decode(FaultTolerantNodeArray.self, forKey: .items)
        self.items = tolerant.nodes
    }

    enum CodingKeys: String, CodingKey {
        case items
    }
}

// MARK: - Table Node

struct TableNode: Codable {
    let id: String
    let title: String?
    let headers: [String]
    let rows: [[String]]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID().uuidString
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.headers = try container.decodeIfPresent([String].self, forKey: .headers) ?? []
        self.rows = try container.decodeIfPresent([[String]].self, forKey: .rows) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case title, headers, rows
    }
}

// MARK: - Color Resolver

extension String {
    var resolvedColor: Color {
        switch self.lowercased() {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "pink": return .pink
        case "yellow": return .yellow
        case "gray", "grey": return .gray
        case "brown": return .brown
        case "cyan": return .cyan
        case "mint": return .mint
        case "teal": return .teal
        case "indigo": return .indigo
        case "white": return .white
        case "black": return .black
        case "primary": return .primary
        case "secondary": return .secondary
        default: return .primary
        }
    }
}
