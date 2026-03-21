import Foundation

/// The top-level response from the LLM describing what UI to render
struct UIResponse: Codable {
    let title: String
    let layout: UINode
    let spokenSummary: String

    enum CodingKeys: String, CodingKey {
        case title
        case layout
        case spokenSummary = "spoken_summary"
    }
}
