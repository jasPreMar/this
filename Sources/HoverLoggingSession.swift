import AppKit
import Foundation

struct HoverSnapshot: Equatable {
    let timestamp: Date
    let processID: pid_t
    let description: String
    let parts: [String]
    let selectedText: String
    let elementFrame: CGRect?
    let windowFrame: CGRect?
    let screenPoint: CGPoint?
    let workingDirectoryURL: URL?

    var identityKey: String {
        [
            "pid=\(processID)",
            "desc=\(description)",
            "sel=\(selectedText)",
            "frame=\(roundedRectString(elementFrame))",
            "window=\(roundedRectString(windowFrame))",
        ].joined(separator: "|")
    }

    var displayText: String {
        let pathText = parts
            .enumerated()
            .map(categorizedPart)
            .joined(separator: " / ")
        if !pathText.isEmpty {
            return pathText
        }
        if !description.isEmpty {
            return description.replacingOccurrences(of: " → ", with: " / ")
        }
        if !selectedText.isEmpty {
            return "selected text: \(selectedText)"
        }
        return "<no hover target>"
    }

    var inlineLogText: String {
        let appName = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetPart = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let targetText: String
        if let separatorRange = targetPart.range(of: ": ") {
            targetText = String(targetPart[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !targetPart.isEmpty {
            targetText = targetPart
        } else if !description.isEmpty {
            targetText = description.replacingOccurrences(of: " → ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !selectedText.isEmpty {
            targetText = selectedText
        } else {
            targetText = "item"
        }

        if !appName.isEmpty {
            return "[hovered \(targetText) in \(appName)]"
        }

        return "[hovered \(targetText)]"
    }

    private func categorizedPart(indexedPart: (offset: Int, element: String)) -> String {
        let normalized = indexedPart.element.replacingOccurrences(of: " → ", with: " / ")
        if let separatorRange = normalized.range(of: ": ") {
            let label = String(normalized[..<separatorRange.lowerBound])
            let value = String(normalized[separatorRange.upperBound...])
            return quotedPart(label: label, value: value)
        }
        return indexedPart.offset == 0
            ? quotedPart(label: "app", value: normalized)
            : quotedPart(label: "item", value: normalized)
    }

    private func quotedPart(label: String, value: String) -> String {
        let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\(label): \"\(escapedValue)\""
    }

    private func roundedRectString(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return [
            Int(rect.origin.x.rounded()),
            Int(rect.origin.y.rounded()),
            Int(rect.size.width.rounded()),
            Int(rect.size.height.rounded()),
        ].map(String.init).joined(separator: ",")
    }
}

final class HoverLoggingSession {
    static let logURL = URL(fileURLWithPath: "/tmp/this-hover.log")

    private weak var searchViewModel: SearchViewModel?
    private let onPauseLogged: ((HoverSnapshot) -> Void)?
    private var dwellTimer: Timer?
    private var fileHandle: FileHandle?
    private var currentSnapshot: HoverSnapshot?
    private var lastObservedPoint: CGPoint?
    private var hasLoggedCurrentPause = false
    private let movementThreshold: CGFloat = 3

    init(
        searchViewModel: SearchViewModel,
        onPauseLogged: ((HoverSnapshot) -> Void)? = nil
    ) {
        self.searchViewModel = searchViewModel
        self.onPauseLogged = onPauseLogged
    }

    func start() {
        stop()

        guard AppSettings.hoverLoggingEnabled else { return }

        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)

        do {
            fileHandle = try FileHandle(forWritingTo: Self.logURL)
            try fileHandle?.truncate(atOffset: 0)
        } catch {
            fileHandle = nil
            return
        }

        searchViewModel?.onHoverSnapshotUpdated = { [weak self] snapshot in
            self?.handleSnapshot(snapshot)
        }

        _ = searchViewModel?.updateHoveredApp()
    }

    func stop() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        currentSnapshot = nil
        lastObservedPoint = nil
        hasLoggedCurrentPause = false
        searchViewModel?.onHoverSnapshotUpdated = nil

        try? fileHandle?.close()
        fileHandle = nil

        if FileManager.default.fileExists(atPath: Self.logURL.path) {
            try? FileManager.default.removeItem(at: Self.logURL)
        }
    }

    private func handleSnapshot(_ snapshot: HoverSnapshot?) {
        guard fileHandle != nil else { return }

        guard let snapshot else {
            resetTrackedPause()
            return
        }

        let identityChanged = snapshot.identityKey != currentSnapshot?.identityKey
        let movedWithinSameTarget = !identityChanged && didMoveEnough(to: snapshot.screenPoint)

        if currentSnapshot == nil || identityChanged || movedWithinSameTarget {
            currentSnapshot = snapshot
            lastObservedPoint = snapshot.screenPoint
            hasLoggedCurrentPause = false
            scheduleDwellTimer()
            return
        }

        currentSnapshot = snapshot
        lastObservedPoint = snapshot.screenPoint ?? lastObservedPoint
    }

    private func scheduleDwellTimer() {
        dwellTimer?.invalidate()
        let timer = Timer(timeInterval: AppSettings.hoverLoggingDwellDelay, repeats: false) { [weak self] _ in
            self?.emitPauseIfNeeded()
        }
        dwellTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func emitPauseIfNeeded() {
        guard let snapshot = currentSnapshot, !hasLoggedCurrentPause else { return }
        writeLine("Mouse pause \(snapshot.displayText)")
        onPauseLogged?(snapshot)
        hasLoggedCurrentPause = true
    }

    private func resetTrackedPause() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        currentSnapshot = nil
        lastObservedPoint = nil
        hasLoggedCurrentPause = false
    }

    private func didMoveEnough(to point: CGPoint?) -> Bool {
        guard let lastObservedPoint, let point else { return false }
        let dx = point.x - lastObservedPoint.x
        let dy = point.y - lastObservedPoint.y
        return hypot(dx, dy) >= movementThreshold
    }

    private func writeLine(_ line: String) {
        guard let fileHandle else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }

        _ = try? fileHandle.seekToEnd()
        try? fileHandle.write(contentsOf: data)
    }
}
