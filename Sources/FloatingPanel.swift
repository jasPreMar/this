import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    let searchViewModel = SearchViewModel()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var hostingView: NSHostingView<PanelContentView>!
    private var isTerminalMode = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false

        hostingView = NSHostingView(rootView: PanelContentView(viewModel: searchViewModel))
        contentView = hostingView

        // Wire up the submit callback
        searchViewModel.onSubmit = { [weak self] context, screenshotURL, screenshotStatus in
            self?.transitionToTerminal(
                message: context,
                screenshotURL: screenshotURL,
                screenshotStatus: screenshotStatus
            )
        }
        searchViewModel.onClose = { [weak self] in
            self?.close()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show(at point: NSPoint) {
        searchViewModel.query = ""
        searchViewModel.updateHoveredApp()

        let fittingSize = hostingView.fittingSize
        setContentSize(fittingSize)

        // Position at click point with slight offset, clamped to screen
        let x = point.x + 4
        let y = point.y - fittingSize.height - 4

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let sf = screen.visibleFrame
            let clampedX = max(sf.minX, min(x, sf.maxX - fittingSize.width))
            let clampedY = max(sf.minY, y)
            setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            setFrameOrigin(NSPoint(x: x, y: y))
        }

        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Dismiss on click outside (no mouse-move monitors — panel stays anchored)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, !self.isTerminalMode else { return }
            self.close()
        }
    }

    func show() {
        searchViewModel.query = ""

        positionAtCursor()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Follow cursor
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.positionAtCursor()
            self?.searchViewModel.updateHoveredApp()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.positionAtCursor()
            self?.searchViewModel.updateHoveredApp()
            return event
        }

        // Dismiss on any click outside
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, !self.isTerminalMode else { return }
            self.close()
        }
    }

    func transitionToTerminal(
        message: String,
        screenshotURL: URL? = nil,
        screenshotStatus: String? = nil
    ) {
        isTerminalMode = true
        removeAllMonitors()

        // Switch to chat mode — the PanelContentView handles the rest
        searchViewModel.chatHistory.append((role: "user", text: searchViewModel.query))
        searchViewModel.query = ""

        let manager = ClaudeProcessManager()
        manager.onComplete = { [weak self] response in
            // Clear streaming text before appending to history to avoid duplicate display
            manager.outputText = ""
            self?.searchViewModel.chatHistory.append((role: "assistant", text: response))
            // Capture session ID for follow-up messages
            if let sid = manager.sessionId {
                self?.searchViewModel.currentSessionId = sid
            }
        }
        searchViewModel.claudeManager = manager
        searchViewModel.isChatMode = true

        manager.start(
            message: message,
            screenshotURL: screenshotURL,
            screenshotDebug: screenshotStatus
        )
    }

    private func positionAtCursor() {
        guard !isTerminalMode else { return }
        let fittingSize = hostingView.fittingSize
        setContentSize(fittingSize)

        let mouse = NSEvent.mouseLocation
        let x = mouse.x + 4
        let y = mouse.y - fittingSize.height - 4

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let clampedX = max(sf.minX, min(x, sf.maxX - fittingSize.width))
            let clampedY = max(sf.minY, y)
            setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func removeAllMonitors() {
        for monitor in [globalMouseMonitor, localMouseMonitor, globalClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        globalClickMonitor = nil
    }

    override func close() {
        removeAllMonitors()
        super.close()
        searchViewModel.query = ""
        searchViewModel.isChatMode = false
        searchViewModel.chatHistory = []
        searchViewModel.claudeManager = nil
        searchViewModel.currentSessionId = nil
        isTerminalMode = false
    }

    // Handle Escape: stop streaming if active, otherwise close
    override func cancelOperation(_ sender: Any?) {
        if let manager = searchViewModel.claudeManager,
           manager.status == .waiting || manager.status == .streaming {
            manager.stop()
        } else {
            close()
        }
    }
}
