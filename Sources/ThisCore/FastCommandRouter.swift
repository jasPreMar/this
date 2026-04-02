import Foundation

public enum FastCommandSurface: String, Equatable {
    case cursorPanel
    case commandMenu
    case taskChat
}

public struct FastInvocationSnapshot: Equatable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let windowTitle: String?

    public init(
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
    }
}

public struct FastCommandContext: Equatable {
    public let prompt: String
    public let surface: FastCommandSurface
    public let hoveredParts: [String]
    public let hoveredFilePath: String?
    public let hoveredWorkingDirectoryPath: String?
    public let selectedText: String
    public let frontmostAppName: String?
    public let frontmostAppBundleID: String?
    public let invocationSnapshot: FastInvocationSnapshot?

    public init(
        prompt: String,
        surface: FastCommandSurface,
        hoveredParts: [String] = [],
        hoveredFilePath: String? = nil,
        hoveredWorkingDirectoryPath: String? = nil,
        selectedText: String = "",
        frontmostAppName: String? = nil,
        frontmostAppBundleID: String? = nil,
        invocationSnapshot: FastInvocationSnapshot? = nil
    ) {
        self.prompt = prompt
        self.surface = surface
        self.hoveredParts = hoveredParts
        self.hoveredFilePath = hoveredFilePath
        self.hoveredWorkingDirectoryPath = hoveredWorkingDirectoryPath
        self.selectedText = selectedText
        self.frontmostAppName = frontmostAppName
        self.frontmostAppBundleID = frontmostAppBundleID
        self.invocationSnapshot = invocationSnapshot
    }
}

public struct FastAppCandidate: Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let isRunning: Bool

    public init(name: String, bundleIdentifier: String? = nil, isRunning: Bool = false) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
    }
}

public struct FastCommandCatalog: Equatable {
    public let apps: [FastAppCandidate]

    public init(apps: [FastAppCandidate]) {
        self.apps = apps
    }
}

public enum FastCommandAction: String, Equatable {
    case open
    case focus
    case hide
    case quit
    case minimize
    case maximize
    case close
    case reveal
    case copyPath
}

public enum FastCommandSubject: Equatable {
    case app(name: String)
    case hoveredApp(name: String)
    case frontmostApp(name: String?)
    case namedWindow(appName: String)
    case frontmostWindow(appName: String?)
    case hoveredWindow(appName: String?)
    case hoveredFile(pathHint: String?)
    case hoveredFolder(pathHint: String?)
    case fileQuery(String)
}

public enum FastAppTarget: Equatable {
    case named(String)
    case hovered(name: String)
    case frontmost(name: String?)
}

public enum FastWindowTarget: Equatable {
    case namedApp(String)
    case hovered(appName: String?)
    case frontmost(appName: String?)
}

public enum FastFileTarget: Equatable {
    case hoveredFile(pathHint: String?)
    case hoveredFolder(pathHint: String?)
    case query(String)
}

public enum FastExecutionPlan: Equatable {
    case app(action: FastCommandAction, target: FastAppTarget)
    case window(action: FastCommandAction, target: FastWindowTarget)
    case file(action: FastCommandAction, target: FastFileTarget)
}

public struct FastCommandMatch: Equatable {
    public let action: FastCommandAction
    public let subject: FastCommandSubject
    public let confidence: Double
    public let scoreMargin: Double
    public let executionPlan: FastExecutionPlan
    public let actionConfidence: Double
    public let subjectConfidence: Double

    public init(
        action: FastCommandAction,
        subject: FastCommandSubject,
        confidence: Double,
        scoreMargin: Double,
        executionPlan: FastExecutionPlan,
        actionConfidence: Double,
        subjectConfidence: Double
    ) {
        self.action = action
        self.subject = subject
        self.confidence = confidence
        self.scoreMargin = scoreMargin
        self.executionPlan = executionPlan
        self.actionConfidence = actionConfidence
        self.subjectConfidence = subjectConfidence
    }
}

public enum FastFallbackReason: String, Equatable {
    case emptyPrompt
    case unsupportedIntent
    case reasoningRequired
    case multiStep
    case textTransform
    case unsupportedSubject
    case noSubject
    case lowConfidence
    case ambiguousSubject
}

public enum FastRouteDecision: Equatable {
    case execute(FastCommandMatch)
    case fallback(FastFallbackReason)
}

public protocol FastCommandClassifier {
    func decide(context: FastCommandContext, catalog: FastCommandCatalog) -> FastRouteDecision
}

public struct RuleBasedFastCommandClassifier: FastCommandClassifier {
    private static let actionThreshold = 0.96
    private static let subjectThreshold = 0.93
    private static let combinedThreshold = 0.95
    private static let marginThreshold = 0.18

    public init() {}

    public func decide(context: FastCommandContext, catalog: FastCommandCatalog) -> FastRouteDecision {
        let prepared = PreparedPrompt(raw: context.prompt)
        guard !prepared.normalized.isEmpty else {
            return .fallback(.emptyPrompt)
        }
        if prepared.requiresReasoning {
            return .fallback(.reasoningRequired)
        }
        if prepared.isTextTransformOnly {
            return .fallback(.textTransform)
        }
        if prepared.isMultiStep {
            return .fallback(.multiStep)
        }
        if prepared.significantTokens.count > 10 {
            return .fallback(.unsupportedIntent)
        }

        guard let actionResult = parseAction(from: prepared) else {
            return .fallback(.unsupportedIntent)
        }
        if actionResult.confidence < Self.actionThreshold {
            return .fallback(.lowConfidence)
        }

        let appMatches = matchApps(query: prepared.subjectQuery, catalog: catalog)
        switch actionResult.action {
        case .open, .focus, .hide, .quit:
            return resolveOpenLikeAction(
                context: context,
                prepared: prepared,
                actionResult: actionResult,
                appMatches: appMatches
            )
        case .minimize, .maximize, .close:
            return resolveWindowAction(
                context: context,
                prepared: prepared,
                actionResult: actionResult,
                appMatches: appMatches
            )
        case .reveal, .copyPath:
            return resolveFileAction(
                context: context,
                prepared: prepared,
                actionResult: actionResult
            )
        }
    }

    private func resolveOpenLikeAction(
        context: FastCommandContext,
        prepared: PreparedPrompt,
        actionResult: ActionResult,
        appMatches: [AppMatch]
    ) -> FastRouteDecision {
        if prepared.prefersWindowTarget {
            return resolveWindowAction(
                context: context,
                prepared: prepared,
                actionResult: actionResult,
                appMatches: appMatches
            )
        }

        if actionResult.action == .open,
           prepared.hasDeicticReference,
           (context.hoveredFilePath != nil || context.hoveredWorkingDirectoryPath != nil) {
            let hoveredFileDecision = resolveFileAction(
                context: context,
                prepared: prepared,
                actionResult: actionResult
            )
            if case .execute = hoveredFileDecision {
                return hoveredFileDecision
            }
        }

        if prepared.prefersFileTarget || prepared.isFileLikeQuery {
            let fileDecision = resolveFileAction(context: context, prepared: prepared, actionResult: actionResult)
            if case .execute = fileDecision {
                return fileDecision
            }
        }

        if prepared.hasDeicticReference,
           let hoveredAppName = hoveredAppName(from: context) {
            return makeDecision(
                action: actionResult.action,
                subject: .hoveredApp(name: hoveredAppName),
                executionPlan: .app(action: actionResult.action, target: .hovered(name: hoveredAppName)),
                actionConfidence: actionResult.confidence,
                subjectConfidence: 0.99,
                scoreMargin: 1.0
            )
        }

        if let best = acceptedAppMatch(appMatches) {
            return makeDecision(
                action: actionResult.action,
                subject: .app(name: best.candidate.name),
                executionPlan: .app(action: actionResult.action, target: .named(best.candidate.name)),
                actionConfidence: actionResult.confidence,
                subjectConfidence: best.score,
                scoreMargin: best.margin
            )
        }

        if prepared.hasDeicticReference,
           let frontmostAppName = frontmostAppName(from: context) {
            return makeDecision(
                action: actionResult.action,
                subject: .frontmostApp(name: frontmostAppName),
                executionPlan: .app(action: actionResult.action, target: .frontmost(name: frontmostAppName)),
                actionConfidence: actionResult.confidence,
                subjectConfidence: 0.96,
                scoreMargin: 1.0
            )
        }

        if prepared.isImplicitOpen {
            return .fallback(.lowConfidence)
        }

        if prepared.subjectQuery.isEmpty {
            return .fallback(.noSubject)
        }
        return .fallback(.ambiguousSubject)
    }

    private func resolveWindowAction(
        context: FastCommandContext,
        prepared: PreparedPrompt,
        actionResult: ActionResult,
        appMatches: [AppMatch]
    ) -> FastRouteDecision {
        if prepared.hasDeicticReference || prepared.subjectQuery.isEmpty {
            let hoveredAppName = hoveredAppName(from: context)
            let frontmost = frontmostAppName(from: context)
            let subject: FastCommandSubject = hoveredAppName != nil
                ? .hoveredWindow(appName: hoveredAppName)
                : .frontmostWindow(appName: frontmost)
            let target: FastWindowTarget = hoveredAppName != nil
                ? .hovered(appName: hoveredAppName)
                : .frontmost(appName: frontmost)
            return makeDecision(
                action: actionResult.action,
                subject: subject,
                executionPlan: .window(action: actionResult.action, target: target),
                actionConfidence: actionResult.confidence,
                subjectConfidence: hoveredAppName != nil ? 0.99 : 0.95,
                scoreMargin: 1.0
            )
        }

        if let best = acceptedAppMatch(appMatches) {
            return makeDecision(
                action: actionResult.action,
                subject: .namedWindow(appName: best.candidate.name),
                executionPlan: .window(action: actionResult.action, target: .namedApp(best.candidate.name)),
                actionConfidence: actionResult.confidence,
                subjectConfidence: best.score,
                scoreMargin: best.margin
            )
        }

        return .fallback(.ambiguousSubject)
    }

    private func resolveFileAction(
        context: FastCommandContext,
        prepared: PreparedPrompt,
        actionResult: ActionResult
    ) -> FastRouteDecision {
        if prepared.hasDeicticReference || prepared.subjectQuery.isEmpty {
            if let hoveredFilePath = context.hoveredFilePath {
                return makeDecision(
                    action: actionResult.action,
                    subject: .hoveredFile(pathHint: hoveredFilePath),
                    executionPlan: .file(action: actionResult.action, target: .hoveredFile(pathHint: hoveredFilePath)),
                    actionConfidence: actionResult.confidence,
                    subjectConfidence: 0.99,
                    scoreMargin: 1.0
                )
            }
            if let hoveredWorkingDirectoryPath = context.hoveredWorkingDirectoryPath {
                return makeDecision(
                    action: actionResult.action,
                    subject: .hoveredFolder(pathHint: hoveredWorkingDirectoryPath),
                    executionPlan: .file(action: actionResult.action, target: .hoveredFolder(pathHint: hoveredWorkingDirectoryPath)),
                    actionConfidence: actionResult.confidence,
                    subjectConfidence: 0.98,
                    scoreMargin: 1.0
                )
            }
        }

        guard !prepared.subjectQuery.isEmpty else {
            return .fallback(.noSubject)
        }

        return makeDecision(
            action: actionResult.action,
            subject: .fileQuery(prepared.subjectQuery),
            executionPlan: .file(action: actionResult.action, target: .query(prepared.subjectQuery)),
            actionConfidence: actionResult.confidence,
            subjectConfidence: prepared.isFileLikeQuery ? 0.97 : 0.94,
            scoreMargin: 1.0
        )
    }

    private func makeDecision(
        action: FastCommandAction,
        subject: FastCommandSubject,
        executionPlan: FastExecutionPlan,
        actionConfidence: Double,
        subjectConfidence: Double,
        scoreMargin: Double
    ) -> FastRouteDecision {
        guard subjectConfidence >= Self.subjectThreshold else {
            return .fallback(.lowConfidence)
        }
        guard scoreMargin >= Self.marginThreshold else {
            return .fallback(.ambiguousSubject)
        }

        let confidence = (actionConfidence + subjectConfidence) / 2
        guard confidence >= Self.combinedThreshold else {
            return .fallback(.lowConfidence)
        }

        return .execute(
            FastCommandMatch(
                action: action,
                subject: subject,
                confidence: confidence,
                scoreMargin: scoreMargin,
                executionPlan: executionPlan,
                actionConfidence: actionConfidence,
                subjectConfidence: subjectConfidence
            )
        )
    }

    private func parseAction(from prepared: PreparedPrompt) -> ActionResult? {
        if prepared.tokens.contains("copy") {
            return prepared.tokens.contains("path")
                ? ActionResult(action: .copyPath, confidence: 0.995, isImplicitOpen: false)
                : nil
        }

        let actions = prepared.tokens.compactMap { token in
            action(for: token)
        }
        let uniqueActions = Array(Set(actions))
        if uniqueActions.count > 1 {
            return nil
        }
        if let explicitAction = uniqueActions.first {
            let confidence: Double = explicitAction == .focus && prepared.tokens.contains("bring")
                ? 0.98
                : 0.995
            return ActionResult(action: explicitAction, confidence: confidence, isImplicitOpen: false)
        }

        if prepared.canImplicitlyOpenApp {
            return ActionResult(action: .open, confidence: 0.97, isImplicitOpen: true)
        }
        return nil
    }

    private func action(for token: String) -> FastCommandAction? {
        switch token {
        case "open":
            return .open
        case "focus":
            return .focus
        case "hide":
            return .hide
        case "quit":
            return .quit
        case "minimize":
            return .minimize
        case "maximize":
            return .maximize
        case "close":
            return .close
        case "reveal", "find":
            return .reveal
        default:
            return nil
        }
    }

    private func acceptedAppMatch(_ matches: [AppMatch]) -> AppMatch? {
        guard let best = matches.first else { return nil }
        guard best.score >= Self.subjectThreshold else { return nil }
        return best
    }

    private func matchApps(query: String, catalog: FastCommandCatalog) -> [AppMatch] {
        let normalizedQuery = normalizeForMatching(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let scored = catalog.apps.map { candidate -> AppMatch in
            let score = fuzzyScore(query: normalizedQuery, candidate: normalizeForMatching(candidate.name))
            let boosted = min(1.0, score + (candidate.isRunning ? 0.02 : 0.0))
            return AppMatch(candidate: candidate, score: boosted)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name) == .orderedAscending
            }
            return lhs.score > rhs.score
        }

        guard let best = scored.first else { return [] }
        let second = scored.dropFirst().first?.score ?? 0
        let margin = best.score - second

        return scored.enumerated().map { index, match in
            AppMatch(
                candidate: match.candidate,
                score: match.score,
                margin: index == 0 ? margin : 0
            )
        }
    }

    private func fuzzyScore(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if query == candidate {
            return 1.0
        }
        if candidate.hasPrefix(query) {
            let slack = Double(candidate.count - query.count) * 0.01
            return max(0.95, 0.995 - slack)
        }
        if candidate.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
            let ratio = Double(query.count) / Double(max(candidate.count, 1))
            return min(0.985, 0.95 + ratio * 0.08)
        }
        guard let subsequencePenalty = subsequencePenalty(query: query, candidate: candidate) else {
            return 0
        }

        let ratio = Double(query.count) / Double(max(candidate.count, 1))
        let base = 0.88 + min(0.08, ratio * 0.08)
        let adjusted = base - subsequencePenalty
        return max(0, min(0.98, adjusted))
    }

    private func subsequencePenalty(query: String, candidate: String) -> Double? {
        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        var queryIndex = 0
        var gapPenalty = 0.0
        var previousMatch = -1

        for (candidateIndex, character) in candidateChars.enumerated() where queryIndex < queryChars.count {
            if character == queryChars[queryIndex] {
                if previousMatch >= 0 {
                    gapPenalty += Double(max(0, candidateIndex - previousMatch - 1)) * 0.01
                }
                previousMatch = candidateIndex
                queryIndex += 1
            }
        }

        return queryIndex == queryChars.count ? gapPenalty : nil
    }

    private func hoveredAppName(from context: FastCommandContext) -> String? {
        context.hoveredParts.first?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func frontmostAppName(from context: FastCommandContext) -> String? {
        context.invocationSnapshot?.appName?.nilIfEmpty
            ?? context.frontmostAppName?.nilIfEmpty
    }
}

private struct ActionResult {
    let action: FastCommandAction
    let confidence: Double
    let isImplicitOpen: Bool
}

private struct AppMatch {
    let candidate: FastAppCandidate
    let score: Double
    let margin: Double

    init(candidate: FastAppCandidate, score: Double, margin: Double = 0) {
        self.candidate = candidate
        self.score = score
        self.margin = margin
    }
}

private struct PreparedPrompt {
    let raw: String
    let normalized: String
    let tokens: [String]
    let significantTokens: [String]

    init(raw: String) {
        self.raw = raw
        self.normalized = PreparedPrompt.normalize(raw)
        self.tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        self.significantTokens = tokens.filter { !PreparedPrompt.fillerWords.contains($0) }
    }

    var lowercasedRaw: String {
        raw.lowercased()
    }

    var requiresReasoning: Bool {
        lowercasedRaw.contains("?")
            || lowercasedRaw.contains("```")
            || significantTokens.contains(where: PreparedPrompt.reasoningWords.contains)
    }

    var isMultiStep: Bool {
        if significantTokens.contains(where: PreparedPrompt.chainedStepWords.contains) {
            return true
        }
        let distinctActions = Set(tokens.compactMap { token in
            PreparedPrompt.verbToNormalized[token]
        })
        return distinctActions.count > 1
    }

    var isTextTransformOnly: Bool {
        tokens.contains("copy") && !tokens.contains("path")
    }

    var prefersWindowTarget: Bool {
        tokens.contains(where: PreparedPrompt.windowWords.contains)
    }

    var prefersFileTarget: Bool {
        tokens.contains(where: PreparedPrompt.fileWords.contains)
            || tokens.contains("reveal")
            || tokens.contains("find")
            || tokens.contains("path")
    }

    var hasDeicticReference: Bool {
        tokens.contains(where: PreparedPrompt.deicticWords.contains)
    }

    var isFileLikeQuery: Bool {
        subjectQuery.contains("/")
            || subjectQuery.contains(".")
            || prefersFileTarget
    }

    var canImplicitlyOpenApp: Bool {
        !tokens.isEmpty
            && tokens.count <= 3
            && tokens.allSatisfy { !PreparedPrompt.reasoningWords.contains($0) }
            && tokens.allSatisfy { !PreparedPrompt.chainedStepWords.contains($0) }
    }

    var isImplicitOpen: Bool {
        tokens.compactMap { PreparedPrompt.verbToNormalized[$0] }.isEmpty && canImplicitlyOpenApp
    }

    var subjectQuery: String {
        let filtered = tokens.filter { token in
            !PreparedPrompt.fillerWords.contains(token)
                && !PreparedPrompt.subjectlessWords.contains(token)
                && PreparedPrompt.verbToNormalized[token] == nil
                && token != "copy"
        }
        return filtered.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let deicticWords: Set<String> = [
        "this", "that", "it", "current", "frontmost", "selected"
    ]
    private static let windowWords: Set<String> = [
        "window", "panel", "dialog", "sheet"
    ]
    private static let fileWords: Set<String> = [
        "file", "folder", "directory", "document", "path"
    ]
    private static let chainedStepWords: Set<String> = [
        "and", "then", "after", "next", "also"
    ]
    private static let reasoningWords: Set<String> = [
        "why", "how", "explain", "fix", "summarize", "summary",
        "plan", "help", "debug", "diagnose", "what"
    ]
    private static let fillerWords: Set<String> = [
        "a", "an", "the", "to", "in", "of", "for", "on", "at",
        "my", "me", "please", "with"
    ]
    private static let subjectlessWords: Set<String> = deicticWords.union(windowWords).union(fileWords).union([
        "app", "application", "up", "forward", "to", "front", "from"
    ])
    private static let verbToNormalized: [String: String] = [
        "open": "open",
        "launch": "open",
        "start": "open",
        "focus": "focus",
        "switch": "focus",
        "activate": "focus",
        "bring": "focus",
        "hide": "hide",
        "quit": "quit",
        "minimize": "minimize",
        "maximise": "maximize",
        "maximize": "maximize",
        "zoom": "maximize",
        "close": "close",
        "show": "reveal",
        "reveal": "reveal",
        "find": "find",
        "copy": "copy"
    ]

    private static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let substituted = normalizeSynonyms(in: lowered)
        var scalarView = String.UnicodeScalarView()
        for scalar in substituted.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == " "
                || scalar == "."
                || scalar == "/"
                || scalar == "-" {
                scalarView.append(scalar)
            } else {
                scalarView.append(" ")
            }
        }

        return String(String(scalarView).split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    private static func normalizeSynonyms(in text: String) -> String {
        var normalized = text
        let replacements = [
            ("launch", "open"),
            ("start", "open"),
            ("switch", "focus"),
            ("activate", "focus"),
            ("show", "reveal"),
            ("maximise", "maximize"),
            ("zoom", "maximize")
        ]

        for (source, replacement) in replacements {
            normalized = normalized.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: source))\\b",
                with: replacement,
                options: .regularExpression
            )
        }
        return normalized
    }
}

private func normalizeForMatching(_ value: String) -> String {
    let lowered = value.lowercased()
    var scalarView = String.UnicodeScalarView()
    for scalar in lowered.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
            scalarView.append(scalar)
        } else {
            scalarView.append(" ")
        }
    }
    return String(String(scalarView).split(whereSeparator: \.isWhitespace).joined(separator: " "))
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
