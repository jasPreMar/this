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
    @Published var activeToolName: String?
    @Published var activeToolStartTime: Date?
    var onComplete: ((String) -> Void)?
    var sessionId: String?

    private var process: Process?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "claude-stream", qos: .userInitiated)
    private var isStopped = false

    func start(
        message: String,
        screenshotURL: URL? = nil,
        resumeSessionId: String? = nil
    ) {
        // Reset stale events from previous messages
        DispatchQueue.main.async {
            self.events = []
            self.outputText = ""
            self.status = .waiting
            self.activeToolName = nil
            self.activeToolStartTime = nil
        }
        isStopped = false
        accumulated = ""
        buffer = Data()


        guard let claudePath = resolveClaudeBinaryPath() else {
            status = .error("Could not find 'claude' binary")
            return
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
            }
        }

        let process = Process()
        self.process = process

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let useStreamJsonInput = stdinData != nil
        let claudeCmd = makeClaudeCommand(
            claudePath: claudePath,
            resumeSessionId: resumeSessionId,
            useStreamJSONInput: useStreamJsonInput
        )
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
            You are HyperPointer, a cursor-aware AI assistant that lives in a floating panel on \
            macOS. The user summons you by hovering over something on their screen and pressing a \
            hotkey. You appear right at their cursor.

            ## What you receive

            Each message may include:
            - **Screenshot** — a PNG of the window the user is hovering over. Use it to see exactly \
            what the user sees: UI state, content, errors, layout.
            - **Accessibility metadata** — structured info extracted from the macOS accessibility \
            tree:
              - *Element*: the specific control under the cursor (button, link, text field, etc.).
              - *Path*: a breadcrumb from the app name down to the element \
            (e.g. "Safari → toolbar → address bar").
              - *URL*: the page URL if the cursor is over a browser.
              - *Selected text*: any text the user has highlighted.
            Together, the screenshot and metadata tell you what the user is pointing at and why \
            they're asking.

            ## What you can do

            You have full access to the Mac through Claude Code's tool suite:
            - Run shell commands (bash).
            - Execute AppleScript via `osascript` to control apps, click buttons, type text, \
            move windows, and automate multi-step workflows.
            - Open apps (`open -a "AppName"`), URLs, and files.
            - Read, write, and manage files anywhere the user has access.
            - Search the web and fetch pages.
            When asked to do something on the Mac — open an app, click a button, fill a form, \
            reorganize files — do it directly. Never say you cannot interact with the GUI.

            ## How you should behave

            - Be concise. The user is mid-task and reading a small floating panel, not a full page.
            - Lead with the answer or action. Skip preamble.
            - Use the screenshot and metadata to ground your response — reference what you can see \
            rather than asking the user to describe it.
            - If the user points at an error, diagnose it. If they point at a UI element, explain \
            or act on it. If they highlight text, work with that text.
            - Prefer action over explanation. If the intent is clear, just do it.
            - When the task is ambiguous, give a short answer and offer to do more.
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

    private func makeClaudeCommand(
        claudePath: String,
        resumeSessionId: String?,
        useStreamJSONInput: Bool
    ) -> String {
        var commandParts = [shellQuoted(claudePath), "--print"]

        if let resumeSessionId {
            commandParts.append("--resume")
            commandParts.append(shellQuoted(resumeSessionId))
        }

        commandParts.append("--model")
        commandParts.append(shellQuoted(AppSettings.defaultModel.rawValue))
        commandParts.append("--thinking")
        commandParts.append(AppSettings.claudeThinkingMode)
        commandParts.append("--settings")
        commandParts.append(shellQuoted(AppSettings.claudeSettingsJSONString))
        commandParts.append("--system-prompt")
        commandParts.append("\"$HP_SYSTEM\"")

        if useStreamJSONInput {
            commandParts.append("--input-format")
            commandParts.append("stream-json")
        } else {
            commandParts.append("-p")
            commandParts.append("\"$HP_MESSAGE\"")
        }

        commandParts.append("--output-format")
        commandParts.append("stream-json")
        commandParts.append("--verbose")
        commandParts.append("--dangerously-skip-permissions")
        commandParts.append("2>&1")

        return commandParts.joined(separator: " ")
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func normalizedScreenshotURL(_ screenshotURL: URL?) -> URL? {
        guard let screenshotURL = screenshotURL else { return nil }
        if FileManager.default.fileExists(atPath: screenshotURL.path) {
            return screenshotURL
        } else {
            return nil
        }
    }

    private func handleData(_ data: Data) {
        guard !isStopped else { return }
        buffer.append(data)

        // Split buffer on newlines, process complete lines
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
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
                        self.activeToolName = name
                        self.activeToolStartTime = Date()
                        self.events.append(.toolCall(id: blockId, name: name, input: inputStr))
                    }
                } else if blockType == "text",
                          let text = block["text"] as? String {
                    accumulated = text
                }
            }
            // Return accumulated text so intermediate responses are visible
            return accumulated.isEmpty ? nil : accumulated
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
                        self.activeToolName = nil
                        self.activeToolStartTime = nil
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
    func stop() {
        isStopped = true
        DispatchQueue.main.async {
            self.activeToolName = nil
            self.activeToolStartTime = nil
        }
        if let proc = process, proc.isRunning {
            let pid = proc.processIdentifier
            // Kill child processes first and wait for completion before
            // killing the parent shell. Without waiting, the shell dies
            // before pkill runs, orphaning the claude process which keeps
            // the stdout pipe open and continues streaming.
            DispatchQueue.global(qos: .userInitiated).async {
                let pkillTask = Process()
                pkillTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pkillTask.arguments = ["-KILL", "-P", "\(pid)"]
                pkillTask.standardOutput = FileHandle.nullDevice
                pkillTask.standardError = FileHandle.nullDevice
                try? pkillTask.run()
                pkillTask.waitUntilExit()
                kill(pid, SIGKILL)
            }
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

// MARK: - Active Tool Indicator

struct ActiveToolIndicatorView: View {
    let toolName: String
    let startTime: Date
    @State private var elapsed: TimeInterval = 0
    @State private var animateDots = false

    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var displayName: String {
        switch toolName.lowercased() {
        case "bash": return "Running command"
        case "read": return "Reading file"
        case "write": return "Writing file"
        case "edit": return "Editing file"
        case "glob": return "Searching files"
        case "grep": return "Searching content"
        case "webfetch": return "Fetching page"
        case "websearch": return "Searching web"
        default: return "Running \(toolName)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)

                Text("\(displayName)\(animateDots ? "..." : "..")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(String(format: "%.0fs", elapsed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            if elapsed >= 30 {
                Text("Press Esc to stop")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .onAppear {
            elapsed = Date().timeIntervalSince(startTime)
        }
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(startTime)
            animateDots.toggle()
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
    let events: [StreamEvent]
    let isDone: Bool
    @State private var isExpanded = false

    private var toolCallCount: Int {
        events.filter {
            if case .toolCall = $0 { return true }
            return false
        }.count
    }

    private var messageCount: Int {
        events.filter {
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
        if events.isEmpty {
            EmptyView()
        } else if isDone {
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
                    ForEach(events) { event in
                        eventRow(for: event)
                    }
                }
            }
        } else {
            // Live streaming — show all events individually
            ForEach(events) { event in
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

// MARK: - Panel Content View (switches between search and chat)

struct PanelContentView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        Group {
            if viewModel.isChatMode {
                ChatView(viewModel: viewModel)
            } else {
                SearchView(viewModel: viewModel)
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PanelContentSizePreferenceKey.self,
                    value: geometry.size
                )
            }
        )
        .onPreferenceChange(PanelContentSizePreferenceKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            viewModel.onContentSizeChange?(size)
        }
    }
}

private struct PanelContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
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

// MARK: - Streaming Content View (observes manager directly for live updates)

struct StreamingContentView: View {
    @ObservedObject var manager: ClaudeProcessManager

    var body: some View {
        EventsSummaryView(events: manager.events, isDone: manager.status == .done)

        if manager.status == .waiting || manager.status == .streaming {
            if let toolName = manager.activeToolName,
               let startTime = manager.activeToolStartTime {
                ActiveToolIndicatorView(toolName: toolName, startTime: startTime)
            }
            StreamingTimerView()
        }

        if !manager.outputText.isEmpty {
            AssistantMarkdown(text: manager.outputText)
        }
    }
}

// MARK: - Chat View (output + input in the floating panel)

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var textWidth: CGFloat = FocusedTextField.minWidth
    @State private var textHeight: CGFloat = 18
    @State private var scrollContentHeight: CGFloat = 0
    private let maxScrollAreaHeight: CGFloat = 500

    var body: some View {
        VStack(spacing: 0) {
            // Context info rendered inside the transparent title bar area.
            // Left padding clears the traffic-light buttons (~76 pt).
            HStack(spacing: 7) {
                if let icon = viewModel.hoveredContextIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if let part = viewModel.hoveredParts.last {
                    Text(contextDisplayText(part))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 76)
            .padding(.trailing, 12)
            .frame(height: 28)

            if !viewModel.selectedText.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                        .frame(width: 16, alignment: .center)
                    Text(viewModel.selectedText)
                        .font(.system(size: 12))
                        .italic()
                        .lineLimit(2)
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
            }

            Divider()
                .padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        transcriptContent
                        Spacer(minLength: 0)
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ScrollContentHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .frame(height: min(max(scrollContentHeight + 16, 60), maxScrollAreaHeight))
                .onPreferenceChange(ScrollContentHeightKey.self) { h in
                    scrollContentHeight = h
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: viewModel.claudeManager?.outputText) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.chatHistory.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.claudeManager?.events.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.claudeManager?.status) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.claudeManager?.activeToolName) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()
                .padding(.horizontal, 8)

            PanelInputRow(
                viewModel: viewModel,
                textWidth: $textWidth,
                textHeight: $textHeight,
                expandsTextField: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    private func contextDisplayText(_ text: String) -> String {
        if let colonRange = text.range(of: ": ") {
            return String(text[colonRange.upperBound...])
        }
        return text
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(viewModel.chatHistory.enumerated()), id: \.offset) { _, entry in
                if entry.role == "user" {
                    Text("> \(entry.text)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    EventsSummaryView(events: entry.events, isDone: true)
                    AssistantMarkdown(text: entry.text)
                }
            }

            if let manager = viewModel.claudeManager {
                StreamingContentView(manager: manager)
            }

            Spacer().frame(height: 0).id("bottom")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
