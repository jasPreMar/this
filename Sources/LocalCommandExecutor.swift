import AppKit
import Foundation
import ThisCore

struct LocalExecutionResult {
    let assistantText: String
    let eventInput: String
    let ghostCursorIntent: GhostCursorIntent?
    let resultingInvocationSnapshot: ExternalFocusSnapshot?
}

struct LocalExecutionContext {
    let prompt: String
    let hoveredParts: [String]
    let hoveredFileURL: URL?
    let hoveredWorkingDirectoryURL: URL?
    let invocationSnapshot: ExternalFocusSnapshot?
    let appCatalogEntries: [AppCatalogEntry]
}

enum LocalExecutionDisposition {
    case completed(LocalExecutionResult)
    case fallback
}

final class LocalCommandExecutor {
    func execute(match: FastCommandMatch, context: LocalExecutionContext) -> LocalExecutionDisposition {
        switch match.executionPlan {
        case .app(let action, let target):
            return executeAppAction(action: action, target: target, context: context)
        case .window(let action, let target):
            return executeWindowAction(action: action, target: target, context: context)
        case .file(let action, let target):
            return executeFileAction(action: action, target: target, context: context)
        }
    }

    private func executeAppAction(
        action: FastCommandAction,
        target: FastAppTarget,
        context: LocalExecutionContext
    ) -> LocalExecutionDisposition {
        guard let resolution = resolveAppTarget(target, context: context) else {
            return .fallback
        }

        let success: Bool
        switch action {
        case .open:
            success = openOrFocusApplication(resolution)
        case .focus:
            success = focusApplication(resolution)
        case .hide:
            success = resolution.runningApplication?.hide() ?? false
        case .quit:
            success = resolution.runningApplication?.terminate() ?? false
        default:
            return .fallback
        }

        guard success else { return .fallback }

        let verb: String
        let intent: GhostCursorIntent?
        switch action {
        case .open:
            verb = "Opened"
            intent = .appLaunch(appName: resolution.name)
        case .focus:
            verb = "Focused"
            intent = .focusWindow(label: "Focused \(resolution.name)")
        case .hide:
            verb = "Hid"
            intent = .genericWork(label: "Hid \(resolution.name)")
        case .quit:
            verb = "Quit"
            intent = .genericWork(label: "Quit \(resolution.name)")
        default:
            verb = "Handled"
            intent = nil
        }

        let text = "\(verb) \(resolution.name)."
        return .completed(
            LocalExecutionResult(
                assistantText: text,
                eventInput: quickActionPayload(
                    command: context.prompt,
                    action: action.rawValue,
                    subject: resolution.name,
                    status: "completed"
                ),
                ghostCursorIntent: intent,
                resultingInvocationSnapshot: snapshot(for: resolution)
            )
        )
    }

    private func executeWindowAction(
        action: FastCommandAction,
        target: FastWindowTarget,
        context: LocalExecutionContext
    ) -> LocalExecutionDisposition {
        guard let resolution = resolveWindowTarget(target, context: context) else {
            return .fallback
        }

        let success: Bool
        switch action {
        case .focus:
            success = focusWindow(resolution)
        case .minimize:
            success = minimizeWindow(resolution.window)
        case .maximize:
            success = zoomWindow(resolution.window)
        case .close:
            success = pressWindowButton(named: kAXCloseButtonAttribute as String, in: resolution.window)
        default:
            return .fallback
        }

        guard success else { return .fallback }

        let subject = resolution.appName ?? "window"
        let text: String
        switch action {
        case .focus:
            text = "Focused \(subject) window."
        case .minimize:
            text = "Minimized \(subject) window."
        case .maximize:
            text = "Maximized \(subject) window."
        case .close:
            text = "Closed \(subject) window."
        default:
            text = "Handled \(subject) window."
        }

        return .completed(
            LocalExecutionResult(
                assistantText: text,
                eventInput: quickActionPayload(
                    command: context.prompt,
                    action: action.rawValue,
                    subject: subject,
                    status: "completed"
                ),
                ghostCursorIntent: .focusWindow(label: text.replacingOccurrences(of: ".", with: "")),
                resultingInvocationSnapshot: snapshot(for: resolution)
            )
        )
    }

    private func executeFileAction(
        action: FastCommandAction,
        target: FastFileTarget,
        context: LocalExecutionContext
    ) -> LocalExecutionDisposition {
        guard let url = resolveFileTarget(target, context: context) else {
            return .fallback
        }

        let success: Bool
        let text: String
        switch action {
        case .open:
            success = NSWorkspace.shared.open(url)
            text = "Opened \(url.lastPathComponent)."
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
            success = true
            text = "Revealed \(url.lastPathComponent) in Finder."
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            success = pasteboard.setString(url.path, forType: .string)
            text = "Copied path for \(url.lastPathComponent)."
        default:
            return .fallback
        }

        guard success else { return .fallback }

        return .completed(
            LocalExecutionResult(
                assistantText: text,
                eventInput: quickActionPayload(
                    command: context.prompt,
                    action: action.rawValue,
                    subject: url.path,
                    status: "completed"
                ),
                ghostCursorIntent: .pathSearch(
                    label: url.lastPathComponent,
                    path: url.path,
                    query: url.lastPathComponent
                ),
                resultingInvocationSnapshot: ExternalFocusInspector.captureCurrent()
            )
        )
    }

    private func resolveAppTarget(
        _ target: FastAppTarget,
        context: LocalExecutionContext
    ) -> AppResolution? {
        switch target {
        case .named(let name), .hovered(let name):
            return appResolution(named: name, preferredPID: nil, entries: context.appCatalogEntries)
        case .frontmost(let name):
            if let snapshot = context.invocationSnapshot {
                return appResolution(
                    named: snapshot.appName ?? name ?? "",
                    preferredPID: snapshot.processIdentifier,
                    entries: context.appCatalogEntries
                )
            }
            return name.flatMap { appResolution(named: $0, preferredPID: nil, entries: context.appCatalogEntries) }
        }
    }

    private func resolveWindowTarget(
        _ target: FastWindowTarget,
        context: LocalExecutionContext
    ) -> WindowResolution? {
        switch target {
        case .namedApp(let appName):
            guard let app = appResolution(named: appName, preferredPID: nil, entries: context.appCatalogEntries),
                  let pid = app.processIdentifier ?? app.runningApplication?.processIdentifier,
                  let window = ExternalFocusInspector.focusedWindow(for: pid) else {
                return nil
            }
            return WindowResolution(appName: app.name, app: app.runningApplication, window: window)
        case .hovered(let appName), .frontmost(let appName):
            let snapshot = context.invocationSnapshot
            let preferredPID = snapshot?.processIdentifier
            let preferredName = snapshot?.appName ?? appName
            guard let app = preferredName.flatMap({
                appResolution(named: $0, preferredPID: preferredPID, entries: context.appCatalogEntries)
            }) ?? preferredPID.flatMap({
                AppResolution(
                    name: snapshot?.appName ?? "window",
                    bundleIdentifier: snapshot?.bundleIdentifier,
                    url: nil,
                    runningApplication: NSRunningApplication(processIdentifier: $0),
                    processIdentifier: $0
                )
            }),
            let pid = app.processIdentifier ?? app.runningApplication?.processIdentifier,
            let window = ExternalFocusInspector.focusedWindow(for: pid) else {
                return nil
            }
            return WindowResolution(appName: app.name, app: app.runningApplication, window: window)
        }
    }

    private func resolveFileTarget(
        _ target: FastFileTarget,
        context: LocalExecutionContext
    ) -> URL? {
        switch target {
        case .hoveredFile(let pathHint):
            return context.hoveredFileURL
                ?? pathHint.map { URL(fileURLWithPath: $0) }
        case .hoveredFolder(let pathHint):
            return context.hoveredWorkingDirectoryURL
                ?? pathHint.map { URL(fileURLWithPath: $0) }
        case .query(let query):
            return resolveFileQuery(query, workingDirectoryURL: context.hoveredWorkingDirectoryURL)
        }
    }

    private func openOrFocusApplication(_ resolution: AppResolution) -> Bool {
        if let runningApplication = resolution.runningApplication {
            return runningApplication.activate(options: [.activateAllWindows])
        }
        guard let url = resolution.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func focusApplication(_ resolution: AppResolution) -> Bool {
        if let runningApplication = resolution.runningApplication {
            return runningApplication.activate(options: [.activateAllWindows])
        }
        guard let url = resolution.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func focusWindow(_ resolution: WindowResolution) -> Bool {
        let appSuccess = resolution.app?.activate(options: [.activateAllWindows]) ?? true
        let raised = AXUIElementPerformAction(resolution.window, kAXRaiseAction as CFString) == .success
        return appSuccess || raised
    }

    private func minimizeWindow(_ window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private func zoomWindow(_ window: AXUIElement) -> Bool {
        pressWindowButton(named: kAXZoomButtonAttribute as String, in: window)
    }

    private func pressWindowButton(named attribute: String, in window: AXUIElement) -> Bool {
        guard let button = ExternalFocusInspector.axElementValue(window, key: attribute) else {
            return false
        }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private func appResolution(
        named name: String,
        preferredPID: pid_t?,
        entries: [AppCatalogEntry]
    ) -> AppResolution? {
        let normalizedName = normalizeCatalogName(name)
        let matchingEntry = entries.first { normalizeCatalogName($0.name) == normalizedName }

        let runningApplication: NSRunningApplication?
        if let preferredPID {
            runningApplication = NSRunningApplication(processIdentifier: preferredPID)
        } else if let bundleIdentifier = matchingEntry?.bundleIdentifier {
            runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated })
        } else {
            runningApplication = NSWorkspace.shared.runningApplications.first {
                !$0.isTerminated && normalizeCatalogName($0.localizedName ?? "") == normalizedName
            }
        }

        let resolvedName = matchingEntry?.name
            ?? runningApplication?.localizedName
            ?? name
        let resolvedURL = matchingEntry?.url ?? runningApplication?.bundleURL

        guard !resolvedName.isEmpty else { return nil }
        if runningApplication == nil && resolvedURL == nil {
            return nil
        }

        return AppResolution(
            name: resolvedName,
            bundleIdentifier: matchingEntry?.bundleIdentifier ?? runningApplication?.bundleIdentifier,
            url: resolvedURL,
            runningApplication: runningApplication,
            processIdentifier: preferredPID ?? runningApplication?.processIdentifier
        )
    }

    private func resolveFileQuery(_ query: String, workingDirectoryURL: URL?) -> URL? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        if trimmedQuery.hasPrefix("/") {
            let directURL = URL(fileURLWithPath: trimmedQuery)
            if FileManager.default.fileExists(atPath: directURL.path) {
                return directURL
            }
        }

        var candidates = mdfindResults(for: trimmedQuery, onlyIn: workingDirectoryURL)
        if candidates.isEmpty {
            candidates = mdfindResults(for: trimmedQuery, onlyIn: nil)
        }

        let ranked = rankFileCandidates(candidates, query: trimmedQuery)
        guard let best = ranked.first else { return nil }
        let secondScore = ranked.dropFirst().first?.score ?? 0
        guard best.score >= 0.93, best.score - secondScore >= 0.18 else {
            return nil
        }
        return best.url
    }

    private func mdfindResults(for query: String, onlyIn directory: URL?) -> [URL] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        var arguments = ["-name", query]
        if let directory {
            arguments = ["-onlyin", directory.path] + arguments
        }
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let string = String(data: data, encoding: .utf8) else { return [] }
            return string
                .split(whereSeparator: \.isNewline)
                .map { URL(fileURLWithPath: String($0)) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        } catch {
            return []
        }
    }

    private func rankFileCandidates(_ candidates: [URL], query: String) -> [(url: URL, score: Double)] {
        let normalizedQuery = normalizeCatalogName(query)
        let deduped = Array(Set(candidates.map(\.path))).map { URL(fileURLWithPath: $0) }

        return deduped.map { url in
            let candidateName = normalizeCatalogName(url.lastPathComponent)
            let score = fileScore(query: normalizedQuery, candidate: candidateName)
            return (url, score)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.url.path.localizedCaseInsensitiveCompare(rhs.url.path) == .orderedAscending
            }
            return lhs.score > rhs.score
        }
    }

    private func fileScore(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if query == candidate {
            return 1.0
        }
        if candidate.hasPrefix(query) {
            return max(0.95, 0.99 - Double(candidate.count - query.count) * 0.01)
        }
        if candidate.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
            return 0.95
        }
        return isSubsequence(query, of: candidate) ? 0.94 : 0.0
    }

    private func isSubsequence(_ query: String, of candidate: String) -> Bool {
        var queryIndex = query.startIndex
        for candidateCharacter in candidate where queryIndex < query.endIndex {
            if candidateCharacter == query[queryIndex] {
                query.formIndex(after: &queryIndex)
            }
        }
        return queryIndex == query.endIndex
    }

    private func quickActionPayload(command: String, action: String, subject: String, status: String) -> String {
        let payload: [String: String] = [
            "command": command,
            "action": action,
            "subject": subject,
            "status": status
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"command":"quick action"}"#
        }
        return string
    }

    private func snapshot(for resolution: AppResolution) -> ExternalFocusSnapshot? {
        let processIdentifier = resolution.processIdentifier ?? resolution.runningApplication?.processIdentifier
        return ExternalFocusSnapshot(
            appName: resolution.name,
            bundleIdentifier: resolution.bundleIdentifier ?? resolution.runningApplication?.bundleIdentifier,
            processIdentifier: processIdentifier,
            windowTitle: processIdentifier.flatMap(ExternalFocusInspector.focusedWindowTitle)
        )
    }

    private func snapshot(for resolution: WindowResolution) -> ExternalFocusSnapshot? {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(resolution.window, &processIdentifier)
        return ExternalFocusSnapshot(
            appName: resolution.appName ?? resolution.app?.localizedName,
            bundleIdentifier: resolution.app?.bundleIdentifier,
            processIdentifier: processIdentifier == 0 ? resolution.app?.processIdentifier : processIdentifier,
            windowTitle: ExternalFocusInspector.stringAttribute("AXTitle", of: resolution.window)
                ?? ExternalFocusInspector.stringAttribute(kAXTitleAttribute as String, of: resolution.window)
        )
    }
}

private struct AppResolution {
    let name: String
    let bundleIdentifier: String?
    let url: URL?
    let runningApplication: NSRunningApplication?
    let processIdentifier: pid_t?
}

private struct WindowResolution {
    let appName: String?
    let app: NSRunningApplication?
    let window: AXUIElement
}
