import AppKit
import Foundation
import ThisCore

struct ExternalFocusSnapshot {
    let appName: String?
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let windowTitle: String?

    var fastInvocationSnapshot: FastInvocationSnapshot? {
        guard appName != nil || bundleIdentifier != nil || windowTitle != nil else { return nil }
        return FastInvocationSnapshot(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle
        )
    }
}

struct QuickActionRequest {
    let prompt: String
    let claudePrompt: String
    let surface: FastCommandSurface
    let hoveredParts: [String]
    let hoveredFileURL: URL?
    let hoveredWorkingDirectoryURL: URL?
    let allowsDeicticFileTarget: Bool
    let selectedText: String
    let invocationSnapshot: ExternalFocusSnapshot?
}

enum QuickActionOutcome {
    case local(LocalExecutionResult)
    case fallback(String)
}

struct AppCatalogEntry {
    let name: String
    let bundleIdentifier: String?
    let url: URL?
    let isRunning: Bool
}

final class QuickActionCoordinator {
    private let classifier: any FastCommandClassifier
    private let appCatalog: QuickActionAppCatalog
    private let executor: LocalCommandExecutor

    init(classifier: any FastCommandClassifier = RuleBasedFastCommandClassifier()) {
        self.classifier = classifier
        self.appCatalog = QuickActionAppCatalog()
        self.executor = LocalCommandExecutor()
    }

    func route(_ request: QuickActionRequest) -> QuickActionOutcome {
        guard AppSettings.quickActionsEnabled else {
            return .fallback(request.claudePrompt)
        }

        let invocationSnapshot = request.invocationSnapshot ?? ExternalFocusInspector.captureCurrent()
        let catalogEntries = appCatalog.snapshot()
        let fastContext = FastCommandContext(
            prompt: request.prompt,
            surface: request.surface,
            hoveredParts: request.hoveredParts,
            hoveredFilePath: request.hoveredFileURL?.path,
            hoveredWorkingDirectoryPath: request.hoveredWorkingDirectoryURL?.path,
            allowsDeicticFileTarget: request.allowsDeicticFileTarget,
            selectedText: request.selectedText,
            frontmostAppName: invocationSnapshot?.appName,
            frontmostAppBundleID: invocationSnapshot?.bundleIdentifier,
            invocationSnapshot: invocationSnapshot?.fastInvocationSnapshot
        )
        let fastCatalog = FastCommandCatalog(
            apps: catalogEntries.map {
                FastAppCandidate(name: $0.name, bundleIdentifier: $0.bundleIdentifier, isRunning: $0.isRunning)
            }
        )

        let decision = classifier.decide(context: fastContext, catalog: fastCatalog)
        guard case .execute(let match) = decision else {
            return .fallback(request.claudePrompt)
        }

        let runtimeContext = LocalExecutionContext(
            prompt: request.prompt,
            hoveredParts: request.hoveredParts,
            hoveredFileURL: request.hoveredFileURL,
            hoveredWorkingDirectoryURL: request.hoveredWorkingDirectoryURL,
            invocationSnapshot: invocationSnapshot,
            appCatalogEntries: catalogEntries
        )

        switch executor.execute(match: match, context: runtimeContext) {
        case .completed(let result):
            appCatalog.refreshSoon()
            return .local(result)
        case .fallback:
            return .fallback(request.claudePrompt)
        }
    }
}

enum ExternalFocusInspector {
    static func captureCurrent() -> ExternalFocusSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        let windowTitle = focusedWindowTitle(for: application.processIdentifier)
        return ExternalFocusSnapshot(
            appName: application.localizedName,
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            windowTitle: windowTitle
        )
    }

    static func focusedWindowTitle(for pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        if let focusedWindow = axElementValue(appElement, key: kAXFocusedWindowAttribute) {
            return stringAttribute("AXTitle", of: focusedWindow)
                ?? stringAttribute(kAXTitleAttribute as String, of: focusedWindow)
        }
        return nil
    }

    static func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        return axElementValue(appElement, key: kAXFocusedWindowAttribute)
            ?? axElementValue(appElement, key: kAXMainWindowAttribute as String)
    }

    static func axElementValue(_ element: AXUIElement, key: String) -> AXUIElement? {
        guard let value = axValue(element, key: key) else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func axValue(_ element: AXUIElement, key: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    static func stringAttribute(_ key: String, of element: AXUIElement) -> String? {
        if let value = axValue(element, key: key) as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

final class QuickActionAppCatalog {
    private let stateQueue = DispatchQueue(label: "this.quick-action-catalog")
    private var entries: [AppCatalogEntry] = []
    private var lastRefreshAt = Date.distantPast

    init() {
        refreshAsync()
    }

    func snapshot() -> [AppCatalogEntry] {
        let needsRefresh = stateQueue.sync {
            entries.isEmpty || Date().timeIntervalSince(lastRefreshAt) > 60
        }
        if needsRefresh {
            refreshSync()
        }
        return stateQueue.sync { entries }
    }

    func refreshSoon() {
        refreshAsync()
    }

    private func refreshAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.refreshSync()
        }
    }

    private func refreshSync() {
        let refreshed = Self.buildEntries()
        stateQueue.sync {
            entries = refreshed
            lastRefreshAt = Date()
        }
    }

    private static func buildEntries() -> [AppCatalogEntry] {
        var resolved: [String: AppCatalogEntry] = [:]

        for application in NSWorkspace.shared.runningApplications where !application.isTerminated {
            let name = resolvedName(for: application.localizedName, url: application.bundleURL)
            guard !name.isEmpty else { continue }
            let entry = AppCatalogEntry(
                name: name,
                bundleIdentifier: application.bundleIdentifier,
                url: application.bundleURL,
                isRunning: true
            )
            resolved[dedupeKey(for: entry)] = entry
        }

        for directory in appSearchDirectories() {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls where url.pathExtension == "app" {
                let entry = AppCatalogEntry(
                    name: resolvedName(for: nil, url: url),
                    bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
                    url: url,
                    isRunning: false
                )
                guard !entry.name.isEmpty else { continue }
                let key = dedupeKey(for: entry)
                if let existing = resolved[key], existing.isRunning {
                    continue
                }
                resolved[key] = entry
            }
        }

        return resolved.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func appSearchDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    private static func dedupeKey(for entry: AppCatalogEntry) -> String {
        if let bundleIdentifier = entry.bundleIdentifier?.lowercased(), !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        return normalizeCatalogName(entry.name)
    }

    private static func resolvedName(for localizedName: String?, url: URL?) -> String {
        if let localizedName, !localizedName.isEmpty {
            return localizedName
        }
        if let bundle = url.flatMap(Bundle.init(url:)),
           let bundleName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String),
           !bundleName.isEmpty {
            return bundleName
        }
        return url?.deletingPathExtension().lastPathComponent ?? ""
    }
}

func normalizeCatalogName(_ value: String) -> String {
    var scalarView = String.UnicodeScalarView()
    for scalar in value.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
            scalarView.append(scalar)
        } else {
            scalarView.append(" ")
        }
    }
    return String(String(scalarView).split(whereSeparator: \.isWhitespace).joined(separator: " "))
}
