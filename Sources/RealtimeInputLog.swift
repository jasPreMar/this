import Foundation

final class RealtimeInputLog {
    static let shared = RealtimeInputLog()
    static let logURL = URL(fileURLWithPath: "/tmp/hyperpointer-live-input.log")

    private struct HoverInsertion {
        let offset: Int
        let text: String
    }

    private let queue = DispatchQueue(label: "hyperpointer.realtime-input-log")
    private var fileHandle: FileHandle?
    private var sessionActive = false
    private var hoverInsertions: [HoverInsertion] = []
    private var currentSpeechTranscript = ""
    private var lastRenderedPreview = ""
    private var lastSpeechPartial = ""

    private init() {}

    func startSession() {
        queue.async {
            self.stopSessionLocked()

            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
            do {
                self.fileHandle = try FileHandle(forWritingTo: Self.logURL)
                try self.fileHandle?.truncate(atOffset: 0)
            } catch {
                self.fileHandle = nil
            }

            self.sessionActive = true
            self.hoverInsertions = []
            self.currentSpeechTranscript = ""
            self.lastRenderedPreview = ""
            self.lastSpeechPartial = ""

            self.writeLocked("Session start")
        }
    }

    func stopSession() {
        queue.async {
            self.stopSessionLocked()
        }
    }

    func finalizeSession(withFinalTranscript transcript: String) -> String? {
        queue.sync {
            guard sessionActive else { return nil }

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                stopSessionLocked()
                return nil
            }

            lastSpeechPartial = trimmed
            currentSpeechTranscript = trimmed
            let preview = renderedPreview()
            if !preview.isEmpty, preview != lastRenderedPreview {
                lastRenderedPreview = preview
                writeLocked(preview)
            }
            stopSessionLocked()
            return preview.isEmpty ? trimmed : preview
        }
    }

    func recordVoiceState(_ state: String) {
        queue.async {
            guard self.sessionActive else { return }
            self.writeLocked("Voice \(state)")
        }
    }

    func recordSpeechPartial(_ transcript: String) {
        queue.async {
            guard self.sessionActive else { return }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != self.lastSpeechPartial else { return }
            self.lastSpeechPartial = trimmed
            self.currentSpeechTranscript = trimmed
            self.emitPreviewLocked()
        }
    }

    func recordSpeechFinal(_ transcript: String) {
        queue.async {
            guard self.sessionActive else { return }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.lastSpeechPartial = trimmed
            self.currentSpeechTranscript = trimmed
            self.emitPreviewLocked()
        }
    }

    func recordHoverPause(_ snapshot: HoverSnapshot) {
        queue.async {
            guard self.sessionActive else { return }
            let insertion = HoverInsertion(
                offset: self.currentSpeechTranscript.count,
                text: snapshot.inlineLogText
            )
            self.hoverInsertions.append(insertion)
            self.emitPreviewLocked()
        }
    }

    private func stopSessionLocked() {
        guard sessionActive || fileHandle != nil else { return }
        writeLocked("Session end")

        try? fileHandle?.close()
        fileHandle = nil
        sessionActive = false
        hoverInsertions = []
        currentSpeechTranscript = ""
        lastRenderedPreview = ""
        lastSpeechPartial = ""
    }

    private func writeLocked(_ line: String) {
        let formattedLine = line + "\n"

        if let data = formattedLine.data(using: .utf8) {
            if let fileHandle {
                _ = try? fileHandle.seekToEnd()
                try? fileHandle.write(contentsOf: data)
            }
        }

        print(formattedLine, terminator: "")
    }

    private func emitPreviewLocked() {
        let preview = renderedPreview()

        guard !preview.isEmpty, preview != lastRenderedPreview else { return }
        lastRenderedPreview = preview
        writeLocked(preview)
    }

    private func renderedPreview() -> String {
        let transcript = currentSpeechTranscript
        let orderedInsertions = hoverInsertions.enumerated().sorted { lhs, rhs in
            if lhs.element.offset == rhs.element.offset {
                return lhs.offset < rhs.offset
            }
            return lhs.element.offset < rhs.element.offset
        }

        guard !transcript.isEmpty || !orderedInsertions.isEmpty else { return "" }

        var pieces: [String] = []
        var currentOffset = 0
        let transcriptCount = transcript.count

        for (_, insertion) in orderedInsertions {
            let clampedOffset = min(max(insertion.offset, 0), transcriptCount)
            if clampedOffset > currentOffset {
                let start = transcript.index(transcript.startIndex, offsetBy: currentOffset)
                let end = transcript.index(transcript.startIndex, offsetBy: clampedOffset)
                let segment = String(transcript[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    pieces.append(segment)
                }
            }

            pieces.append(insertion.text)
            currentOffset = clampedOffset
        }

        if currentOffset < transcriptCount {
            let start = transcript.index(transcript.startIndex, offsetBy: currentOffset)
            let segment = String(transcript[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                pieces.append(segment)
            }
        }

        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
