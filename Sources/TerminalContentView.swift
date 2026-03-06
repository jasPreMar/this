import AppKit
import SwiftUI
import Combine
import MarkdownUI

// MARK: - Stream Event Models

enum StreamEvent: Identifiable, Equatable {
    case thinking(id: String, text: String)
    case toolCall(id: String, name: String, input: String)
    case text(id: String, text: String)

    var id: String {
        switch self {
        case .thinking(let id, _): return id
        case .toolCall(let id, _, _): return id
        case .text(let id, _): return id
        }
    }
}

// MARK: - Stream Status

enum StreamStatus: Equatable {
    case waiting
    case streaming
    case done
    case error(String)
}

// MARK: - Claude Process Manager

class ClaudeProcessManager: ObservableObject {
    @Published var outputText = ""
    @Published var status: StreamStatus = .waiting
    @Published var events: [StreamEvent] = []
    @Published var diagnostics: [String] = []
    var onComplete: ((String) -> Void)?
    var sessionId: String?

    private var process: Process?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "claude-stream", qos: .userInitiated)
    private var isStopped = false
    private var jsonLineCount = 0
    private var nonJSONLineCount = 0
    private var stderrLineCount = 0
    private var nonJSONPreviewCount = 0
    private var runStartedAt: Date?
    private let maxDiagnostics = 80

    func start(
        message: String,
        screenshotURL: URL? = nil,
        resumeSessionId: String? = nil,
        screenshotDebug: String? = nil
    ) {
        // Reset stale events from previous messages
        DispatchQueue.main.async {
            self.events = []
            self.outputText = ""
            self.status = .waiting
            self.diagnostics = []
        }
        isStopped = false
        accumulated = ""
        buffer = Data()
        jsonLineCount = 0
        nonJSONLineCount = 0
        stderrLineCount = 0
        nonJSONPreviewCount = 0
        runStartedAt = Date()

        guard let claudePath = resolveClaudePath() else {
            status = .error("Could not find 'claude' binary")
            return
        }
        addDiagnostic("Claude binary: \(claudePath)")
        if let sid = resumeSessionId {
            addDiagnostic("Session mode: resume \(sid)")
        } else {
            addDiagnostic("Session mode: new")
        }
        if let screenshotDebug, !screenshotDebug.isEmpty {
            addDiagnostic(screenshotDebug)
        } else if screenshotURL == nil {
            addDiagnostic("Screenshot not requested for this message")
        }

        let effectiveScreenshotURL = normalizedScreenshotURL(screenshotURL)

        // Build stdin JSON payload when image is available (--image flag was removed from claude CLI)
        var stdinData: Data?
        if let imageURL = effectiveScreenshotURL,
           let imageData = try? Data(contentsOf: imageURL) {
            let base64Image = imageData.base64EncodedString()
            let messageContent: [[String: Any]] = [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64Image]],
                ["type": "text", "text": message]
            ]
            let userMessage: [String: Any] = [
                "type": "user",
                "message": ["role": "user", "content": messageContent]
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: userMessage) {
                stdinData = jsonData + Data("\n".utf8)
                addDiagnostic("Image attachment: \(imageData.count / 1024) KB → stream-json stdin")
            } else {
                addDiagnostic("Image attachment: JSON encoding failed, skipping image")
            }
        } else if screenshotURL != nil {
            addDiagnostic("Image attachment skipped")
        }

        let process = Process()
        self.process = process

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var claudeCmd: String
        let useStreamJsonInput = stdinData != nil
        let systemPromptFlag = "--system-prompt \"$HP_SYSTEM\""
        if useStreamJsonInput {
            if let sid = resumeSessionId {
                claudeCmd = "\(claudePath) --print --resume \(sid) \(systemPromptFlag) --input-format stream-json --output-format stream-json --verbose --dangerously-skip-permissions 2>&1"
            } else {
                claudeCmd = "\(claudePath) --print \(systemPromptFlag) --input-format stream-json --output-format stream-json --verbose --dangerously-skip-permissions 2>&1"
            }
        } else {
            if let sid = resumeSessionId {
                claudeCmd = "\(claudePath) --print --resume \(sid) \(systemPromptFlag) -p \"$HP_MESSAGE\" --output-format stream-json --verbose --dangerously-skip-permissions 2>&1"
            } else {
                claudeCmd = "\(claudePath) --print \(systemPromptFlag) -p \"$HP_MESSAGE\" --output-format stream-json --verbose --dangerously-skip-permissions 2>&1"
            }
        }
        process.arguments = ["-l", "-c", claudeCmd]

        // Set up stdin: pipe for image data, null device for text-only
        let stdinPipe: Pipe?
        if stdinData != nil {
            stdinPipe = Pipe()
            process.standardInput = stdinPipe
        } else {
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        // Build clean environment
        var env = ProcessInfo.processInfo.environment
        let claudeKeys = env.keys.filter { $0.uppercased().contains("CLAUDE") }
        for key in claudeKeys { env.removeValue(forKey: key) }
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin",
                          NSHomeDirectory() + "/.local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        env["HP_MESSAGE"] = message
        env["HP_SYSTEM"] = """
            You are HyperPointer, an AI assistant embedded in macOS. You have full access to the \
            Mac: open apps (open -a "AppName"), run AppleScript via osascript, automate the UI, \
            manage files, browse the web, run shell commands, and more. When asked to open an app, \
            click a button, type text, or do anything on the Mac, do it directly — never say you \
            cannot control the GUI. Use bash and osascript freely.
            """
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Read stdout on a background thread (more reliable than readabilityHandler)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = stdout.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break } // EOF
                self?.queue.async { self?.handleData(data) }
            }
        }

        // Read stderr on a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = stderr.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.stderrLineCount += text.split(whereSeparator: \.isNewline).count
                        if let firstLine = text.split(whereSeparator: \.isNewline).first {
                            self?.addDiagnostic("stderr: \(String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                        self?.outputText += "[STDERR] \(text)\n"
                        if case .waiting = self?.status { self?.status = .streaming }
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            // Clean up screenshot temp file
            if let screenshotURL = effectiveScreenshotURL {
                try? FileManager.default.removeItem(at: screenshotURL)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let seconds = self.runStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                self.addDiagnostic(
                    String(
                        format: "Process exit: %d (%.1fs), JSON lines: %d, non-JSON lines: %d, stderr lines: %d",
                        proc.terminationStatus,
                        seconds,
                        self.jsonLineCount,
                        self.nonJSONLineCount,
                        self.stderrLineCount
                    )
                )
                if case .error = self.status { return }
                if self.isStopped || proc.terminationStatus == 0 {
                    self.status = .done
                    if !self.isStopped { self.onComplete?(self.accumulated) }
                } else {
                    self.status = .error("Exit code \(proc.terminationStatus)")
                }
            }
        }

        do {
            try process.run()
            addDiagnostic("Process started (pid: \(process.processIdentifier))")
            // Write image JSON to stdin after process starts (async to avoid pipe-buffer deadlock)
            if let pipe = stdinPipe, let data = stdinData {
                DispatchQueue.global(qos: .userInitiated).async {
                    pipe.fileHandleForWriting.write(data)
                    pipe.fileHandleForWriting.closeFile()
                }
            }
        } catch {
            status = .error("Failed to launch: \(error.localizedDescription)")
            return
        }
    }

    private func normalizedScreenshotURL(_ screenshotURL: URL?) -> URL? {
        guard let screenshotURL = screenshotURL else { return nil }
        if FileManager.default.fileExists(atPath: screenshotURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: screenshotURL.path),
           let bytes = attrs[.size] as? NSNumber {
            let kb = max(1, bytes.intValue / 1024)
            addDiagnostic("Screenshot temp file: \(screenshotURL.lastPathComponent) (\(kb) KB)")
            return screenshotURL
        } else {
            addDiagnostic("Screenshot temp file missing: \(screenshotURL.lastPathComponent)")
            return nil
        }
    }

    private func handleData(_ data: Data) {
        buffer.append(data)

        // Split buffer on newlines, process complete lines
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }

            if isJSONObject(line) {
                jsonLineCount += 1
            } else {
                nonJSONLineCount += 1
                if nonJSONPreviewCount < 8 {
                    let preview = String(line.prefix(200))
                    addDiagnostic("Non-JSON output: \(preview)")
                    nonJSONPreviewCount += 1
                }
            }

            let text = extractText(from: line)
            DispatchQueue.main.async {
                if case .waiting = self.status { self.status = .streaming }
                if let text = text {
                    self.outputText = text
                }
            }
        }
    }

    private var accumulated = ""

    private func extractText(from jsonLine: String) -> String? {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        // Capture session ID from system init message
        if type == "system",
           let sid = json["session_id"] as? String {
            DispatchQueue.main.async { self.sessionId = sid }
            return nil
        }

        // Final result — complete text, use as source of truth
        if type == "result",
           let result = json["result"] as? String {
            if let sid = json["session_id"] as? String {
                DispatchQueue.main.async { self.sessionId = sid }
            }
            accumulated = result
            return accumulated
        }

        // CLI format: assistant messages contain complete content arrays
        if type == "assistant",
           let message = json["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                guard let blockType = block["type"] as? String else { continue }

                if blockType == "thinking",
                   let thinkingText = block["thinking"] as? String {
                    let blockId = UUID().uuidString
                    DispatchQueue.main.async {
                        self.events.append(.thinking(id: blockId, text: thinkingText))
                    }
                } else if blockType == "tool_use" {
                    let blockId = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "unknown"
                    var inputStr = ""
                    if let input = block["input"] {
                        if let inputData = try? JSONSerialization.data(withJSONObject: input),
                           let inputJson = String(data: inputData, encoding: .utf8) {
                            inputStr = inputJson
                        }
                    }
                    DispatchQueue.main.async {
                        self.events.append(.toolCall(id: blockId, name: name, input: inputStr))
                    }
                } else if blockType == "text",
                          let text = block["text"] as? String {
                    accumulated = text
                    // Don't set hasText — only show text from "result" event
                }
            }
            return nil
        }

        // CLI format: user messages contain tool results
        if type == "user",
           let message = json["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "tool_result",
                   let toolUseId = block["tool_use_id"] as? String,
                   let resultContent = block["content"] as? String {
                    // Update matching tool call event with output info
                    let preview = String(resultContent.prefix(200))
                    DispatchQueue.main.async {
                        if let idx = self.events.firstIndex(where: { $0.id == toolUseId }),
                           case let .toolCall(id, name, input) = self.events[idx] {
                            // Append result preview to input for display
                            let combined = input.isEmpty ? preview : input + "\n→ " + preview
                            self.events[idx] = .toolCall(id: id, name: name, input: combined)
                        }
                    }
                }
            }
            return nil
        }

        return nil
    }

    private func isJSONObject(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return json is [String: Any]
    }

    private func addDiagnostic(_ line: String) {
        DispatchQueue.main.async {
            self.diagnostics.append(line)
            if self.diagnostics.count > self.maxDiagnostics {
                self.diagnostics.removeFirst(self.diagnostics.count - self.maxDiagnostics)
            }
        }
    }

    private func resolveClaudePath() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: use zsh to resolve
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = result, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    func stop() {
        isStopped = true
        if let proc = process {
            let pid = proc.processIdentifier
            // Kill child processes (claude may be a child of the zsh wrapper)
            let pkillTask = Process()
            pkillTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkillTask.arguments = ["-KILL", "-P", "\(pid)"]
            pkillTask.standardOutput = FileHandle.nullDevice
            pkillTask.standardError = FileHandle.nullDevice
            try? pkillTask.run()
            // SIGKILL the main process — cannot be caught or ignored
            kill(pid, SIGKILL)
        }
        DispatchQueue.main.async { self.status = .done }
    }

    deinit {
        process?.terminate()
    }
}

// MARK: - Streaming Timer View

struct StreamingTimerView: View {
    @State private var elapsed: TimeInterval = 0
    @State private var animateIcon = false

    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .opacity(animateIcon ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: animateIcon)

            Text(String(format: "%.1fs", elapsed))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .onAppear {
            elapsed = 0
            animateIcon = true
        }
        .onReceive(timer) { _ in
            elapsed += 0.1
        }
    }
}

// MARK: - Thinking Event Row

struct ThinkingEventRow: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text("Thinking")
                    .font(.system(size: 12, weight: .bold))

                if !isExpanded {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if isExpanded {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.leading, 22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }
}

// MARK: - Tool Call Event Row

struct ToolCallEventRow: View {
    let name: String
    let input: String
    @State private var isExpanded = false

    var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: iconName(for: name))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 14, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: name))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    if !inputPreview.isEmpty {
                        Text(isExpanded ? input : inputPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(isExpanded ? nil : 1)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var inputPreview: String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let cmd = json["command"] as? String {
                return cmd.components(separatedBy: .newlines).first ?? cmd
            }
            if let path = json["file_path"] as? String {
                return path
            }
            if let pattern = json["pattern"] as? String {
                return pattern
            }
            if let query = json["query"] as? String {
                return query
            }
        }
        return trimmed.components(separatedBy: .newlines).first ?? trimmed
    }

    private func iconName(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "edit": return "square.and.pencil"
        case "glob": return "doc.text.magnifyingglass"
        case "grep": return "magnifyingglass"
        default: return "wrench"
        }
    }

    private func displayName(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash": return "Run command"
        case "read": return "Read file"
        case "write": return "Write file"
        case "edit": return "Edit file"
        case "glob": return "Search files"
        case "grep": return "Search content"
        default: return tool
        }
    }
}

// MARK: - Events Summary View

struct EventsSummaryView: View {
    @ObservedObject var manager: ClaudeProcessManager
    @State private var isExpanded = false

    private var toolCallCount: Int {
        manager.events.filter {
            if case .toolCall = $0 { return true }
            return false
        }.count
    }

    private var messageCount: Int {
        manager.events.filter {
            if case .thinking = $0 { return true }
            return false
        }.count
    }

    private var summaryText: String {
        var parts: [String] = []
        if toolCallCount > 0 {
            parts.append("\(toolCallCount) tool call\(toolCallCount == 1 ? "" : "s")")
        }
        if messageCount > 0 {
            parts.append("\(messageCount) message\(messageCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No events" : parts.joined(separator: ", ")
    }

    var body: some View {
        if manager.events.isEmpty {
            EmptyView()
        } else if manager.status == .done {
            // Collapsed summary with expand/collapse toggle
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 10)

                        Text(summaryText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)

                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(manager.events) { event in
                        eventRow(for: event)
                    }
                }
            }
        } else {
            // Live streaming — show all events individually
            ForEach(manager.events) { event in
                eventRow(for: event)
            }
        }
    }

    @ViewBuilder
    private func eventRow(for event: StreamEvent) -> some View {
        switch event {
        case .thinking(_, let text):
            ThinkingEventRow(text: text)
        case .toolCall(_, let name, let input):
            ToolCallEventRow(name: name, input: input)
        case .text:
            EmptyView()
        }
    }
}

struct DiagnosticsView: View {
    let lines: [String]
    let isLive: Bool
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    Image(systemName: "ladybug")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text(isLive ? "Run diagnostics (live)" : "Run diagnostics")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Panel Content View (switches between search and chat)

struct PanelContentView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        if viewModel.isChatMode {
            ChatView(viewModel: viewModel)
        } else {
            SearchView(viewModel: viewModel)
        }
    }
}

// MARK: - Markdown message renderer

private extension Theme {
    static let assistant = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(13)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
        }
        .heading1 { configuration in
            configuration.label.markdownTextStyle {
                FontWeight(.bold)
                FontSize(.em(1.1))
            }
        }
        .heading2 { configuration in
            configuration.label.markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(1.05))
            }
        }
        .heading3 { configuration in
            configuration.label.markdownTextStyle {
                FontWeight(.semibold)
            }
        }
        .codeBlock { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.25))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.9))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(6)
        }
}

private struct AssistantMarkdown: View {
    let text: String
    var body: some View {
        Markdown(text)
            .markdownTheme(.assistant)
            .textSelection(.enabled)
    }
}

// MARK: - Chat View (output + input in the floating panel)

struct ChatView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var textHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            // Draggable header with close button and status
            HStack(spacing: 6) {
                Button(action: { viewModel.onClose?() }) {
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)

                if let manager = viewModel.claudeManager {
                    statusIndicator(for: manager)
                    statusLabel(for: manager)
                }

                Spacer()

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DragArea())

            // Scrollable output
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(viewModel.chatHistory.enumerated()), id: \.offset) { _, entry in
                            if entry.role == "user" {
                                Text("> \(entry.text)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                AssistantMarkdown(text: entry.text)
                            }
                        }

                        if let manager = viewModel.claudeManager {
                            EventsSummaryView(manager: manager)
                        }

                        if let manager = viewModel.claudeManager,
                           !manager.diagnostics.isEmpty {
                            DiagnosticsView(
                                lines: manager.diagnostics,
                                isLive: manager.status == .waiting || manager.status == .streaming
                            )
                        }

                        if let manager = viewModel.claudeManager,
                           manager.status == .waiting || manager.status == .streaming {
                            StreamingTimerView()
                        }

                        if let manager = viewModel.claudeManager,
                           !manager.outputText.isEmpty,
                           manager.status == .done {
                            AssistantMarkdown(text: manager.outputText)
                        }

                        Spacer().frame(height: 0).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.claudeManager?.outputText) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            // Input field
            HStack(alignment: .top, spacing: 4) {
                Text(">")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.top, 1)

                FocusedTextField(text: $viewModel.query, textHeight: $textHeight, onSubmit: {
                    viewModel.submitMessage()
                })
                .frame(height: textHeight)

                if let manager = viewModel.claudeManager,
                   manager.status == .waiting || manager.status == .streaming {
                    Button(action: {
                        manager.stop()
                    }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 3)
                    .help("Stop generation")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: 360, height: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
        .padding(16)
    }

    @ViewBuilder
    private func statusIndicator(for manager: ClaudeProcessManager) -> some View {
        switch manager.status {
        case .waiting:
            Circle().fill(.orange).frame(width: 6, height: 6)
        case .streaming:
            Circle().fill(.green).frame(width: 6, height: 6)
        case .done:
            Circle().fill(.blue).frame(width: 6, height: 6)
        case .error:
            Circle().fill(.red).frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private func statusLabel(for manager: ClaudeProcessManager) -> some View {
        switch manager.status {
        case .waiting:
            Text("Connecting...").font(.caption2).foregroundColor(.secondary)
        case .streaming:
            Text("Streaming...").font(.caption2).foregroundColor(.green)
        case .done:
            EmptyView()
        case .error(let msg):
            Text(msg).font(.caption2).foregroundColor(.red).lineLimit(1)
        }
    }
}

// MARK: - Drag Area (makes the header draggable)

struct DragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
