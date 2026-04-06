import Foundation

public enum CommandMenuCompletionAction: String, Codable {
    case reveal
    case preserve
}

public struct AssistantResponseDirectiveParseResult {
    public let sanitizedText: String
    public let completionAction: CommandMenuCompletionAction
    public let hasExplicitDirective: Bool

    public init(
        sanitizedText: String,
        completionAction: CommandMenuCompletionAction,
        hasExplicitDirective: Bool
    ) {
        self.sanitizedText = sanitizedText
        self.completionAction = completionAction
        self.hasExplicitDirective = hasExplicitDirective
    }
}

public func shouldRevealCommandMenuOnCompletion(
    isEligibleForReveal: Bool,
    completionAction: CommandMenuCompletionAction,
    isCommandMenuVisible: Bool,
    isCommandMenuDismissing: Bool
) -> Bool {
    guard isEligibleForReveal, completionAction == .reveal else { return false }
    return !isCommandMenuVisible || isCommandMenuDismissing
}

public func shouldMarkCompletedTaskUnread(
    completionAction: CommandMenuCompletionAction,
    isTaskVisibleToUser: Bool
) -> Bool {
    guard completionAction != .preserve else { return false }
    return !isTaskVisibleToUser
}

public func shouldAutoDismissFloatingPanelOnCompletion(
    completionAction: CommandMenuCompletionAction,
    isTaskIconMode: Bool
) -> Bool {
    isTaskIconMode
}

public func shouldMarkTaskEligibleForClosedCommandMenuReveal(
    isCommandMenuVisible: Bool
) -> Bool {
    !isCommandMenuVisible
}

public enum AssistantResponseDirectiveParser {
    private static let plainTextDirectivePrefix = "[[HP_COMMAND_MENU:"
    private static let plainTextDirectiveSuffix = "]]"
    private static let structuredUIDirectiveKey = "_hpCommandMenu"

    public static func parse(_ text: String) -> AssistantResponseDirectiveParseResult {
        if let jsonText = wholeResponseJSONObjectString(from: text),
           let structuredResult = parseStructuredUIResponse(jsonText) {
            return structuredResult
        }

        return parsePlainTextResponse(text)
    }

    public static func wholeResponseJSONObjectString(from text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("```") {
            guard let newlineIndex = trimmed.firstIndex(of: "\n") else { return nil }
            trimmed = String(trimmed[trimmed.index(after: newlineIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix("```") else { return nil }
            trimmed = String(trimmed.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return firstBalancedJSONObjectString(from: trimmed)
    }

    private static func parseStructuredUIResponse(_ jsonText: String) -> AssistantResponseDirectiveParseResult? {
        guard let data = jsonText.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let rawDirective = object.removeValue(forKey: structuredUIDirectiveKey) as? String
        let action = completionAction(from: rawDirective) ?? .reveal
        let hasExplicitDirective = completionAction(from: rawDirective) != nil
        let sanitizedText = sanitizedJSONString(from: object) ?? jsonText

        return AssistantResponseDirectiveParseResult(
            sanitizedText: sanitizedText,
            completionAction: action,
            hasExplicitDirective: hasExplicitDirective
        )
    }

    private static func parsePlainTextResponse(_ text: String) -> AssistantResponseDirectiveParseResult {
        var lines = text.components(separatedBy: .newlines)
        guard let lastDirectiveIndex = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return AssistantResponseDirectiveParseResult(
                sanitizedText: text,
                completionAction: .reveal,
                hasExplicitDirective: false
            )
        }

        let directiveLine = lines[lastDirectiveIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard directiveLine.hasPrefix(plainTextDirectivePrefix),
              directiveLine.hasSuffix(plainTextDirectiveSuffix) else {
            return AssistantResponseDirectiveParseResult(
                sanitizedText: text,
                completionAction: .reveal,
                hasExplicitDirective: false
            )
        }

        let valueStart = directiveLine.index(directiveLine.startIndex, offsetBy: plainTextDirectivePrefix.count)
        let valueEnd = directiveLine.index(directiveLine.endIndex, offsetBy: -plainTextDirectiveSuffix.count)
        let rawDirective = String(directiveLine[valueStart..<valueEnd])

        lines.remove(at: lastDirectiveIndex)
        while let lastLine = lines.last,
              lastLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        let action = completionAction(from: rawDirective) ?? .reveal
        let hasExplicitDirective = completionAction(from: rawDirective) != nil

        return AssistantResponseDirectiveParseResult(
            sanitizedText: lines.joined(separator: "\n"),
            completionAction: action,
            hasExplicitDirective: hasExplicitDirective
        )
    }

    private static func completionAction(from rawDirective: String?) -> CommandMenuCompletionAction? {
        guard let rawDirective else { return nil }

        switch rawDirective.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case CommandMenuCompletionAction.reveal.rawValue:
            return .reveal
        case CommandMenuCompletionAction.preserve.rawValue:
            return .preserve
        default:
            return nil
        }
    }

    private static func sanitizedJSONString(from object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private static func firstBalancedJSONObjectString(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for index in text[start...].indices {
            let character = text[index]

            if escaped {
                escaped = false
                continue
            }

            if character == "\\" && inString {
                escaped = true
                continue
            }

            if character == "\"" {
                inString.toggle()
                continue
            }

            if inString { continue }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
        }

        return nil
    }
}
