import AppKit
import Foundation

enum GhostCursorActivityKind: String {
    case click
    case appLaunch
    case pathSearch
    case focusWindow
    case genericWork

    var requiresClickFeedback: Bool {
        switch self {
        case .click:
            return true
        case .appLaunch, .pathSearch, .focusWindow, .genericWork:
            return false
        }
    }
}

enum GhostCursorConfidence: Int {
    case coarse
    case inferred
    case exact
}

enum GhostCursorTarget: Equatable {
    case point(CGPoint)
    case rect(CGRect)
    case none

    var screenPoint: CGPoint? {
        switch self {
        case .point(let point):
            return point
        case .rect(let rect):
            return rect.center
        case .none:
            return nil
        }
    }
}

struct GhostCursorActivity {
    let taskId: UUID
    let timestamp: Date
    let kind: GhostCursorActivityKind
    let label: String?
    let screenPoint: CGPoint?
    let confidence: GhostCursorConfidence
}

enum GhostCursorIntent {
    case click(label: String?)
    case appLaunch(appName: String)
    case pathSearch(label: String?, path: String?, query: String?)
    case focusWindow(label: String?)
    case genericWork(label: String?)

    var revealsCursor: Bool {
        switch self {
        case .click, .appLaunch, .focusWindow:
            return true
        case .pathSearch, .genericWork:
            return false
        }
    }
}

extension GhostCursorIntent {
    static func fromToolUse(name: String, inputJSONString: String) -> GhostCursorIntent {
        switch name.lowercased() {
        case "bash":
            return parseBashIntent(from: inputJSONString)
        case "glob":
            let payload = toolPayload(from: inputJSONString)
            let path = stringValue(forKeys: ["path"], in: payload)
            let pattern = stringValue(forKeys: ["pattern"], in: payload)
            let label = [
                "Searching",
                pattern.flatMap { $0.isEmpty ? nil : $0 },
                path.flatMap { basename($0) }
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            return .pathSearch(
                label: label.isEmpty ? "Searching files" : label,
                path: path,
                query: pattern
            )
        case "grep":
            let payload = toolPayload(from: inputJSONString)
            let pattern = stringValue(forKeys: ["pattern", "query"], in: payload)
            let path = stringValue(forKeys: ["path"], in: payload)
            let label = pattern.map { "Searching for \($0)" } ?? "Searching content"
            return .pathSearch(label: label, path: path, query: pattern)
        case "read":
            let payload = toolPayload(from: inputJSONString)
            let path = stringValue(forKeys: ["file_path", "path"], in: payload)
            return .genericWork(label: path.map { "Reading \(basename($0))" } ?? "Reading file")
        case "write":
            let payload = toolPayload(from: inputJSONString)
            let path = stringValue(forKeys: ["file_path", "path"], in: payload)
            return .genericWork(label: path.map { "Writing \(basename($0))" } ?? "Writing file")
        case "edit":
            let payload = toolPayload(from: inputJSONString)
            let path = stringValue(forKeys: ["file_path", "path"], in: payload)
            return .genericWork(label: path.map { "Editing \(basename($0))" } ?? "Editing file")
        case "websearch":
            let payload = toolPayload(from: inputJSONString)
            let query = stringValue(forKeys: ["query"], in: payload)
            return .genericWork(label: query.map { "Searching web for \($0)" } ?? "Searching web")
        case "webfetch":
            let payload = toolPayload(from: inputJSONString)
            let url = stringValue(forKeys: ["url"], in: payload)
            return .genericWork(label: url.map { "Fetching \($0)" } ?? "Fetching page")
        default:
            return .genericWork(label: "Running \(name)")
        }
    }

    private static func parseBashIntent(from inputJSONString: String) -> GhostCursorIntent {
        let payload = toolPayload(from: inputJSONString)
        let command = stringValue(forKeys: ["command"], in: payload)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !command.isEmpty else {
            return .genericWork(label: "Running command")
        }

        if let appName = firstMatch(
            in: command,
            patterns: [
                #"\bopen\s+-a\s+["']([^"']+)["']"#,
                #"\bopen\s+/Applications/([^/]+)\.app"#,
                #"\btell\s+application\s+["']([^"']+)["']\s+to\s+(?:activate|launch)\b"#,
            ]
        ) {
            return .appLaunch(appName: appName)
        }

        if isClickCommand(command) {
            return .click(label: clickLabel(from: command))
        }

        if isSearchCommand(command) {
            return .pathSearch(label: "Searching project", path: nil, query: nil)
        }

        if command.contains(" open ") || command.hasPrefix("open ") {
            return .focusWindow(label: conciseCommandLabel(command))
        }

        return .genericWork(label: conciseCommandLabel(command))
    }

    private static func toolPayload(from inputJSONString: String) -> [String: Any] {
        guard let data = inputJSONString.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return payload
    }

    private static func stringValue(forKeys keys: [String], in payload: [String: Any]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func basename(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private static func firstMatch(in source: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            guard let match = expression.firstMatch(in: source, options: [], range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: source) else {
                continue
            }
            return String(source[captureRange])
        }
        return nil
    }

    private static func isClickCommand(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return lowered.contains("cliclick")
            || lowered.contains(" axpress")
            || lowered.contains(" click ")
            || lowered.contains("click button")
            || lowered.contains("click menu")
            || lowered.contains("perform action")
    }

    private static func isSearchCommand(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let markers = ["find ", "mdfind", "grep ", " rg ", "fd ", "locate ", "tree ", "ls "]
        return markers.contains { lowered.contains($0) || lowered.hasPrefix($0) }
    }

    private static func clickLabel(from command: String) -> String {
        if let target = firstMatch(
            in: command,
            patterns: [
                #"click\s+(?:button|menu item|checkbox|row|item)\s+["']([^"']+)["']"#,
                #"press\s+button\s+["']([^"']+)["']"#,
            ]
        ) {
            return "Clicking \(target)"
        }

        return "Clicking"
    }

    private static func conciseCommandLabel(_ command: String) -> String {
        let firstLine = command.components(separatedBy: .newlines).first ?? command
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 52 else { return trimmed }
        return String(trimmed.prefix(49)) + "..."
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func lerp(from start: CGPoint, to end: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
