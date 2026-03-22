import AppKit
import Combine
import CoreGraphics

class SearchViewModel: ObservableObject {
    enum VoiceState: Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    @Published var query: String = ""
    @Published var hoveredApp: String = ""
    @Published var hoveredParts: [String] = []
    @Published var hoveredContextIcon: NSImage?
    @Published var hoveredElementFrame: CGRect?
    @Published var hoveredScreenPoint: CGPoint?
    @Published var hoveredWindowFrame: CGRect?
    @Published var hoveredWorkingDirectoryURL: URL?
    @Published var selectedText: String = ""
    @Published var isChatMode = false
    @Published var isCommandKeyMode = false
    @Published var isMinimalMode = false
    @Published var claudeManager: ClaudeProcessManager? {
        didSet {
            onClaudeManagerChange?(claudeManager)
        }
    }
    @Published var chatHistory: [ChatMessage] = []
    @Published var voiceState: VoiceState = .idle
    @Published var voiceLevel: CGFloat = 0
    var currentSessionId: String?
    var currentSessionWorkingDirectoryURL: URL?
    var onContentSizeChange: ((CGSize) -> Void)?
    var onClaudeManagerChange: ((ClaudeProcessManager?) -> Void)?
    private var hoveredAppPID: pid_t = 0

    // Stale accessibility tree detection
    private var lastCursorPosition: CGPoint = .zero
    private var consecutiveContainerResults: Int = 0
    private var lastContainerRole: String = ""
    private let staleThreshold = 3

    /// Set by FloatingPanel
    var onSubmit: ((String, URL?) -> Void)?
    var onClose: (() -> Void)?
    var onMessageSent: (() -> Void)?
    var onStreamingComplete: (() -> Void)?
    var onHoverSnapshotUpdated: ((HoverSnapshot?) -> Void)?

    var isVoiceModeActive: Bool {
        switch voiceState {
        case .idle:
            return false
        case .listening, .transcribing, .failed:
            return true
        }
    }

    func submitMessage() {
        let message = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        onMessageSent?()

        if isChatMode {
            // Follow-up message — resume the existing session
            chatHistory.append(ChatMessage(role: "user", text: message))
            query = ""
            let manager = ClaudeProcessManager()
            manager.onComplete = { [weak self] response in
                let completedEvents = manager.events
                manager.outputText = ""
                manager.events = []
                self?.chatHistory.append(ChatMessage(role: "assistant", text: response, events: completedEvents, structuredUI: manager.structuredUIResponse))
                // Update session ID in case it changed
                if let sid = manager.sessionId {
                    self?.currentSessionId = sid
                }
                self?.onStreamingComplete?()
            }
            claudeManager = manager
            manager.start(
                message: message,
                resumeSessionId: currentSessionId,
                workingDirectoryURL: currentSessionWorkingDirectoryURL
            )
        } else {
            // First message — switch to chat mode
            let context = buildContextMessage()
            onSubmit?(context, hoveredWorkingDirectoryURL)
        }
    }

    func buildContextMessage() -> String {
        var lines: [String] = []

        if !hoveredParts.isEmpty {
            // Last part is most specific element, first is app name
            let appName = hoveredParts.first ?? ""
            let element = hoveredParts.count > 1 ? hoveredParts.last! : ""

            if !element.isEmpty {
                lines.append("I'm looking at: \(element) in \(appName)")
            } else if !appName.isEmpty {
                lines.append("I'm looking at: \(appName)")
            }

            if hoveredParts.count > 1 {
                lines.append("Path: \(hoveredParts.joined(separator: " → "))")
            }

            // Extract URL if present
            for part in hoveredParts {
                if part.hasPrefix("url: ") {
                    lines.append("URL: \(String(part.dropFirst(5)))")
                    break
                }
            }
        }

        if !selectedText.isEmpty {
            lines.append("Selected text: \(selectedText)")
        }

        if !lines.isEmpty {
            lines.append("")
        }
        lines.append(query)

        return lines.joined(separator: "\n")
    }

    func captureHoveredWindowScreenshot() -> (URL?, String) {
        captureScreenshot(for: hoveredAppPID)
    }

    func captureFullScreenScreenshot() -> (URL?, String) {
        captureScreenshot(for: 0)
    }

    func configureHomeFolderContext() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let homeName = FileManager.default.displayName(atPath: homeURL.path)

        hoveredApp = homeName
        hoveredParts = [homeName]
        hoveredContextIcon = NSWorkspace.shared.icon(forFile: homeURL.path)
        hoveredElementFrame = nil
        hoveredScreenPoint = nil
        hoveredWindowFrame = nil
        hoveredWorkingDirectoryURL = homeURL
        selectedText = ""
        hoveredAppPID = 0
    }

    private func captureScreenshot(for targetPID: pid_t) -> (URL?, String) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return (nil, "Screenshot not captured: screen recording permission not granted")
        }

        let cgImage: CGImage?

        if targetPID == 0 {
            // No hovered element — capture the entire screen
            cgImage = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [])
        } else {
            guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
                return (nil, "Screenshot not captured: failed to enumerate windows")
            }

            let appWindows = windowList.filter {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == targetPID
            }

            let sortedWindows = appWindows.sorted {
                ($0[kCGWindowLayer as String] as? Int ?? 999) < ($1[kCGWindowLayer as String] as? Int ?? 999)
            }

            guard let topWindow = sortedWindows.first,
                  let windowID = topWindow[kCGWindowNumber as String] as? CGWindowID else {
                return (nil, "Screenshot not captured: no visible window for hovered app")
            }

            // Extract bounds of the topmost window.
            var windowRect = CGRect.zero
            if let boundsDict = topWindow[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &windowRect)
            }

            let isBrowser = NSRunningApplication(processIdentifier: targetPID)
                .flatMap { $0.bundleIdentifier }
                .map { browserBundleIDs.contains($0) } ?? false

            // Full-screen detection: check the LARGEST window of the app, not just the topmost
            // layer one. In full screen mode the topmost window is often just a tiny title bar
            // strip while the actual content occupies the display in a separate layer window.
            let largestRect: CGRect = appWindows.reduce(.zero) { best, win in
                var r = CGRect.zero
                if let d = win[kCGWindowBounds as String] as? NSDictionary {
                    CGRectMakeWithDictionaryRepresentation(d as CFDictionary, &r)
                }
                return r.width * r.height > best.width * best.height ? r : best
            }
            let isFullScreen = NSScreen.screens.contains { screen in
                largestRect.width >= screen.frame.width * 0.95 &&
                largestRect.height >= screen.frame.height * 0.95
            }

            if isFullScreen {
                // Capture the full display under the mouse cursor using CG display coordinates.
                let mouse = NSEvent.mouseLocation
                let mainH = NSScreen.screens[0].frame.height
                let cgMouse = CGPoint(x: mouse.x, y: mainH - mouse.y)
                var displayID = CGMainDisplayID()
                var count: UInt32 = 0
                CGGetDisplaysWithPoint(cgMouse, 1, &displayID, &count)
                cgImage = CGWindowListCreateImage(
                    CGDisplayBounds(displayID), .optionOnScreenOnly, kCGNullWindowID, []
                )
            } else if isBrowser && !windowRect.isEmpty {
                cgImage = CGWindowListCreateImage(windowRect, .optionOnScreenOnly, kCGNullWindowID, [])
            } else {
                cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming])
            }
        }

        guard let cgImage = cgImage else {
            return (nil, "Screenshot not captured: CGWindowListCreateImage failed")
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return (nil, "Screenshot not captured: failed to encode PNG data")
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hp_screenshot_\(UUID().uuidString).png")
        do {
            try pngData.write(to: tempURL)
            let kb = max(1, pngData.count / 1024)
            return (tempURL, "Screenshot captured: \(cgImage.width)x\(cgImage.height), \(kb) KB")
        } catch {
            return (nil, "Screenshot not captured: failed to write temp file (\(error.localizedDescription))")
        }
    }

    @discardableResult
    func updateHoveredApp() -> HoverSnapshot? {
        let mouseLocation = NSEvent.mouseLocation
        let desktopFrame = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }
        let cgPoint = CGPoint(x: mouseLocation.x, y: desktopFrame.maxY - mouseLocation.y)

        let cursorMoved = cgPoint != lastCursorPosition
        lastCursorPosition = cgPoint
        hoveredScreenPoint = mouseLocation

        // Use Accessibility API to get the element under the cursor
        var systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        var result = AXUIElementCopyElementAtPosition(systemWide, Float(cgPoint.x), Float(cgPoint.y), &element)

        guard result == .success, let rawElement = element else {
            hoveredApp = ""
            hoveredParts = []
            hoveredContextIcon = nil
            hoveredElementFrame = nil
            hoveredWindowFrame = nil
            hoveredWorkingDirectoryURL = nil
            consecutiveContainerResults = 0
            lastContainerRole = ""
            onHoverSnapshotUpdated?(nil)
            return nil
        }

        // Detect stale accessibility tree: if cursor is moving but we keep getting
        // the same container-level role, force a fresh query by recreating systemWide
        var resolvedElement = rawElement
        if cursorMoved {
            let role = axValue(rawElement, key: kAXRoleAttribute) as? String ?? ""
            if containerRoles.contains(role) && role == lastContainerRole {
                consecutiveContainerResults += 1
                if consecutiveContainerResults >= staleThreshold {
                    // Force a fresh accessibility query
                    systemWide = AXUIElementCreateSystemWide()
                    element = nil
                    result = AXUIElementCopyElementAtPosition(systemWide, Float(cgPoint.x), Float(cgPoint.y), &element)
                    if result == .success, let freshElement = element {
                        resolvedElement = freshElement
                    }
                    consecutiveContainerResults = 0
                }
            } else if containerRoles.contains(role) {
                // New container role — start tracking
                consecutiveContainerResults = 1
                lastContainerRole = role
            } else {
                // Got a non-container result — reset tracking
                consecutiveContainerResults = 0
                lastContainerRole = ""
            }
        }

        // Store the PID of the hovered app for screenshot use
        var pid: pid_t = 0
        AXUIElementGetPid(resolvedElement, &pid)
        if let app = NSRunningApplication(processIdentifier: pid) {
            hoveredAppPID = pid
            hoveredContextIcon = app.icon
        } else {
            hoveredContextIcon = nil
        }
        hoveredWorkingDirectoryURL = resolveWorkingDirectory(for: resolvedElement, pid: pid)
        hoveredElementFrame = resolvedElementFrame(for: resolvedElement)
        hoveredWindowFrame = focusedWindowFrame(for: pid)

        // Build a description from the element hierarchy
        let description = describeElement(resolvedElement)
        if hoveredApp != description {
            hoveredApp = description
            hoveredParts = description.isEmpty ? [] : description.components(separatedBy: " → ")
        }

        // Check for selected/highlighted text
        let sel = getSelectedText(element: resolvedElement)
        if selectedText != sel {
            selectedText = sel
        }

        let snapshot = HoverSnapshot(
            timestamp: Date(),
            processID: hoveredAppPID,
            description: description,
            parts: hoveredParts,
            selectedText: selectedText,
            elementFrame: hoveredElementFrame,
            windowFrame: hoveredWindowFrame,
            screenPoint: hoveredScreenPoint,
            workingDirectoryURL: hoveredWorkingDirectoryURL
        )
        onHoverSnapshotUpdated?(snapshot)
        return snapshot
    }

    private func getSelectedText(element: AXUIElement) -> String {
        // Try getting selected text from the element itself
        if let sel = axValue(element, key: kAXSelectedTextAttribute) as? String, !sel.isEmpty {
            return truncated(sel.trimmingCharacters(in: .whitespacesAndNewlines), max: 80)
        }

        // Walk up to check parent elements
        var current = element
        for _ in 0..<4 {
            guard let parent = axValue(current, key: kAXParentAttribute) else { break }
            let parentEl = parent as! AXUIElement
            if let sel = axValue(parentEl, key: kAXSelectedTextAttribute) as? String, !sel.isEmpty {
                return truncated(sel.trimmingCharacters(in: .whitespacesAndNewlines), max: 80)
            }
            current = parentEl
        }

        // Try the app's focused element (handles selections in text editors, etc.)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let appEl = AXUIElementCreateApplication(pid)
        if let focused = axValue(appEl, key: kAXFocusedUIElementAttribute) {
            let focusedEl = focused as! AXUIElement
            if let sel = axValue(focusedEl, key: kAXSelectedTextAttribute) as? String, !sel.isEmpty {
                return truncated(sel.trimmingCharacters(in: .whitespacesAndNewlines), max: 80)
            }
        }

        return ""
    }

    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi"
    ]

    // Interactive/item-level roles — use as primary element
    private let primaryRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox",
        "AXRadioButton", "AXSlider", "AXPopUpButton", "AXComboBox",
        "AXMenuItem", "AXMenuBarItem", "AXTab", "AXCell", "AXRow",
        "AXHeading", "AXDockItem", "AXDisclosureTriangle",
        "AXColorWell", "AXIncrementor",
        "AXStaticText", "AXImage"
    ]

    // Container roles — good as ancestor context but too broad as primary
    private let containerRoles: Set<String> = [
        "AXList", "AXTable", "AXOutline", "AXToolbar", "AXTabGroup",
        "AXScrollArea", "AXSplitGroup", "AXGroup"
    ]

    private let meaningfulRoles: Set<String> = {
        var s: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox",
            "AXRadioButton", "AXSlider", "AXPopUpButton", "AXComboBox",
            "AXMenuItem", "AXMenuBarItem", "AXTab", "AXCell", "AXRow",
            "AXHeading", "AXDockItem", "AXDisclosureTriangle",
            "AXColorWell", "AXIncrementor",
            "AXList", "AXTable", "AXOutline", "AXToolbar", "AXTabGroup",
            "AXStaticText", "AXImage"
        ]
        return s
    }()

    /// Walk up from the leaf element to find the most meaningful ancestor.
    private func resolveElement(_ element: AXUIElement) -> (primary: AXUIElement, ancestors: [AXUIElement]) {
        let leafRole = axValue(element, key: kAXRoleAttribute) as? String ?? ""

        // If the leaf is already a primary interactive element, use it
        if primaryRoles.contains(leafRole) {
            return (element, collectAncestors(above: element))
        }

        // If the leaf has selected text, use it directly — like right-click on a selection
        let leafSel = axValue(element, key: kAXSelectedTextAttribute) as? String ?? ""
        if !leafSel.isEmpty {
            return (element, collectAncestors(above: element))
        }

        // Walk up to find a primary element (skip containers)
        var current = element
        var bestContainer: AXUIElement? = nil

        for _ in 0..<6 {
            guard let parent = axValue(current, key: kAXParentAttribute) else { break }
            let parentEl = parent as! AXUIElement
            let parentRole = axValue(parentEl, key: kAXRoleAttribute) as? String ?? ""

            if primaryRoles.contains(parentRole) {
                return (parentEl, collectAncestors(above: parentEl))
            }

            // Remember the first container we pass through
            if containerRoles.contains(parentRole) && bestContainer == nil {
                bestContainer = parentEl
            }

            if parentRole == "AXWebArea" || parentRole == "AXWindow" || parentRole == "AXApplication" {
                break
            }

            current = parentEl
        }

        // If we found no primary but the leaf has useful text, use it with context
        let leafTitle = axValue(element, key: kAXTitleAttribute) as? String ?? ""
        let leafDesc = axValue(element, key: kAXDescriptionAttribute) as? String ?? ""
        let leafValue = axValue(element, key: kAXValueAttribute) as? String ?? ""
        let hasContent = !leafTitle.isEmpty || !leafDesc.isEmpty || !leafValue.isEmpty

        if hasContent {
            return (element, collectAncestors(above: element))
        }

        // Fall back to the container if we found one, but first try to find a more specific child
        if let container = bestContainer {
            if let betterChild = findBestChild(in: container) {
                return (betterChild, collectAncestors(above: betterChild))
            }
            return (container, collectAncestors(above: container))
        }

        return (element, collectAncestors(above: element))
    }

    private func collectAncestors(above element: AXUIElement) -> [AXUIElement] {
        var ancestors: [AXUIElement] = []
        var current = element
        for _ in 0..<6 {
            guard let parent = axValue(current, key: kAXParentAttribute) else { break }
            let parentEl = parent as! AXUIElement
            let parentRole = axValue(parentEl, key: kAXRoleAttribute) as? String ?? ""
            if parentRole == "AXApplication" || parentRole == "AXWindow" { break }
            if meaningfulRoles.contains(parentRole) {
                ancestors.append(parentEl)
            }
            current = parentEl
        }
        return ancestors
    }

    /// Search children of a container for a more specific primary-role element.
    /// Caps recursion at 3 levels to avoid performance issues.
    private func findBestChild(in container: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 3,
              let children = axValue(container, key: kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }

        // First pass: look for a direct child with a primary role
        for child in children.prefix(20) {
            let role = axValue(child, key: kAXRoleAttribute) as? String ?? ""
            if primaryRoles.contains(role) {
                return child
            }
        }

        // Second pass: recurse into container children
        for child in children.prefix(20) {
            let role = axValue(child, key: kAXRoleAttribute) as? String ?? ""
            if containerRoles.contains(role) {
                if let found = findBestChild(in: child, depth: depth + 1) {
                    return found
                }
            }
        }

        return nil
    }

    private func describeElement(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier ?? ""

        let isBrowser = browserBundleIDs.contains(bundleID)

        // Resolve to the meaningful element (e.g., button instead of span inside button)
        let (primary, ancestors) = resolveElement(element)

        let role = axValue(primary, key: kAXRoleAttribute) as? String ?? ""
        let subrole = axValue(primary, key: kAXSubroleAttribute) as? String ?? ""
        let title = axValue(primary, key: kAXTitleAttribute) as? String ?? ""
        let desc = axValue(primary, key: kAXDescriptionAttribute) as? String ?? ""
        let roleDesc = axValue(primary, key: kAXRoleDescriptionAttribute) as? String ?? ""
        let value = axValue(primary, key: kAXValueAttribute) as? String ?? ""

        let readableRole = humanRole(role, subrole: subrole, roleDesc: roleDesc)

        // For static text, prefer value (the text content itself) over title/desc
        let elementName: String
        if role == "AXStaticText" {
            let textContent = firstNonEmpty(value, title, desc)
            elementName = truncated(textContent, max: 60)
        } else {
            elementName = firstNonEmpty(title, desc, truncated(value, max: 40))
        }

        // Check if the primary element has selected text — treat it as "selected text" context
        let primarySel = axValue(primary, key: kAXSelectedTextAttribute) as? String ?? ""
        let hasSelection = !primarySel.isEmpty

        var parts: [String] = []

        if !appName.isEmpty { parts.append(appName) }

        if isBrowser {
            let pageURL = browserPageURL(pid: pid)
            if !pageURL.isEmpty { parts.append("url: \(pageURL)") }

            // Add meaningful ancestors (e.g., nav, toolbar)
            for ancestor in ancestors.reversed() {
                let aRole = axValue(ancestor, key: kAXRoleAttribute) as? String ?? ""
                let aSubrole = axValue(ancestor, key: kAXSubroleAttribute) as? String ?? ""
                let aTitle = axValue(ancestor, key: kAXTitleAttribute) as? String ?? ""
                let aDesc = axValue(ancestor, key: kAXDescriptionAttribute) as? String ?? ""
                let aRoleDesc = axValue(ancestor, key: kAXRoleDescriptionAttribute) as? String ?? ""
                let aReadable = humanRole(aRole, subrole: aSubrole, roleDesc: aRoleDesc)
                let aName = firstNonEmpty(aTitle, aDesc)
                if !aName.isEmpty {
                    parts.append("\(aReadable): \(aName)")
                }
            }

            let webInfo = webElementInfo(primary)
            if !webInfo.isEmpty { parts.append(contentsOf: webInfo) }

            if hasSelection {
                parts.append("selected text: \(truncated(primarySel, max: 60))")
            } else if !elementName.isEmpty {
                parts.append("\(readableRole): \(elementName)")
            } else if !readableRole.isEmpty && readableRole != "web content" {
                parts.append(readableRole)
            }
        } else {
            // Add meaningful ancestors
            for ancestor in ancestors.reversed() {
                let aRole = axValue(ancestor, key: kAXRoleAttribute) as? String ?? ""
                let aSubrole = axValue(ancestor, key: kAXSubroleAttribute) as? String ?? ""
                let aTitle = axValue(ancestor, key: kAXTitleAttribute) as? String ?? ""
                let aDesc = axValue(ancestor, key: kAXDescriptionAttribute) as? String ?? ""
                let aRoleDesc = axValue(ancestor, key: kAXRoleDescriptionAttribute) as? String ?? ""
                let aReadable = humanRole(aRole, subrole: aSubrole, roleDesc: aRoleDesc)
                let aName = firstNonEmpty(aTitle, aDesc)
                if !aName.isEmpty && aName != appName {
                    parts.append("\(aReadable): \(aName)")
                }
            }

            if hasSelection {
                parts.append("selected text: \(truncated(primarySel, max: 60))")
            } else if !elementName.isEmpty {
                parts.append("\(readableRole): \(elementName)")
            } else if !readableRole.isEmpty {
                parts.append(readableRole)
            }
        }

        return parts.joined(separator: " → ")
    }

    private func browserPageURL(pid: pid_t) -> String {
        let appElement = AXUIElementCreateApplication(pid)

        guard let focusedWindow = axValue(appElement, key: kAXFocusedWindowAttribute) else { return "" }
        let window = focusedWindow as! AXUIElement

        // Try getting the document URL directly (Safari supports this)
        if let docURL = axValue(window, key: "AXDocument") as? String {
            return truncated(docURL, max: 60)
        }

        // For Chrome/others: find the address bar
        if let urlBarValue = findAddressBar(in: window) {
            return truncated(urlBarValue, max: 60)
        }

        return ""
    }

    private func resolveWorkingDirectory(for element: AXUIElement, pid: pid_t) -> URL? {
        let (primary, ancestors) = resolveElement(element)

        for candidate in [primary, element] + ancestors {
            if let url = localFilesystemURL(from: candidate),
               let workingDirectoryURL = normalizedWorkingDirectoryURL(from: url) {
                return workingDirectoryURL
            }
        }

        let appElement = AXUIElementCreateApplication(pid)
        if let focusedWindow = axValue(appElement, key: kAXFocusedWindowAttribute),
           let url = localFilesystemURL(from: focusedWindow as! AXUIElement),
           let workingDirectoryURL = normalizedWorkingDirectoryURL(from: url) {
            return workingDirectoryURL
        }

        return nil
    }

    private func localFilesystemURL(from element: AXUIElement) -> URL? {
        if let url = axValue(element, key: "AXURL") as? URL, url.isFileURL {
            return url
        }
        if let rawURL = axValue(element, key: "AXURL") as? String,
           let url = parseFilesystemURL(rawURL) {
            return url
        }
        if let document = axValue(element, key: "AXDocument") as? String,
           let url = parseFilesystemURL(document) {
            return url
        }
        if let filename = axValue(element, key: "AXFilename") as? String,
           let url = parseFilesystemURL(filename) {
            return url
        }
        return nil
    }

    private func parseFilesystemURL(_ rawValue: String) -> URL? {
        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue)
        }
        if let url = URL(string: rawValue), url.isFileURL {
            return url
        }
        return nil
    }

    private func normalizedWorkingDirectoryURL(from url: URL) -> URL? {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolvedURL.path
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? resolvedURL : resolvedURL.deletingLastPathComponent()
        }

        if resolvedURL.hasDirectoryPath {
            return resolvedURL
        }

        let parentURL = resolvedURL.deletingLastPathComponent()
        return parentURL.path.isEmpty ? nil : parentURL
    }

    private func findAddressBar(in element: AXUIElement) -> String? {
        let role = axValue(element, key: kAXRoleAttribute) as? String ?? ""
        let subrole = axValue(element, key: kAXSubroleAttribute) as? String ?? ""

        if role == "AXTextField" || subrole == "AXURLTextField" {
            if let value = axValue(element, key: kAXValueAttribute) as? String,
               value.contains(".") && !value.contains(" ") {
                return value
            }
        }

        guard let children = axValue(element, key: kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children.prefix(20) {
            let childRole = axValue(child, key: kAXRoleAttribute) as? String ?? ""
            if ["AXToolbar", "AXGroup", "AXSplitGroup"].contains(childRole) {
                if let found = findAddressBar(in: child) { return found }
            }
            if childRole == "AXTextField" {
                if let value = axValue(child, key: kAXValueAttribute) as? String,
                   value.contains(".") && !value.contains(" ") {
                    return value
                }
            }
        }
        return nil
    }

    private func webElementInfo(_ element: AXUIElement) -> [String] {
        var info: [String] = []

        if let domID = axValue(element, key: "AXDOMIdentifier") as? String, !domID.isEmpty {
            info.append("id: #\(domID)")
        }

        if let classList = axValue(element, key: "AXDOMClassList") as? [String], !classList.isEmpty {
            let classes = classList.prefix(3).joined(separator: ".")
            info.append("class: .\(classes)")
        }

        if let url = axValue(element, key: "AXURL") as? URL {
            info.append("href: \(truncated(url.absoluteString, max: 50))")
        } else if let url = axValue(element, key: "AXURL") as? String, !url.isEmpty {
            info.append("href: \(truncated(url, max: 50))")
        }

        if let help = axValue(element, key: kAXHelpAttribute) as? String, !help.isEmpty {
            info.append("tip: \(truncated(help, max: 40))")
        }

        return info
    }

    private func humanRole(_ role: String, subrole: String, roleDesc: String) -> String {
        if !roleDesc.isEmpty { return roleDesc }

        let map: [String: String] = [
            "AXButton": "button",
            "AXTextField": "text field",
            "AXTextArea": "text area",
            "AXStaticText": "text",
            "AXImage": "image",
            "AXCheckBox": "checkbox",
            "AXRadioButton": "radio button",
            "AXSlider": "slider",
            "AXPopUpButton": "dropdown",
            "AXComboBox": "combo box",
            "AXLink": "link",
            "AXToolbar": "toolbar",
            "AXTabGroup": "tab group",
            "AXTab": "tab",
            "AXTable": "table",
            "AXRow": "row",
            "AXCell": "cell",
            "AXColumn": "column",
            "AXScrollBar": "scroll bar",
            "AXScrollArea": "scroll area",
            "AXGroup": "group",
            "AXList": "list",
            "AXOutline": "outline",
            "AXSplitGroup": "split view",
            "AXWindow": "window",
            "AXSheet": "sheet",
            "AXDialog": "dialog",
            "AXPanel": "panel",
            "AXMenuBar": "menu bar",
            "AXMenuBarItem": "menu",
            "AXMenuItem": "menu item",
            "AXMenuButton": "menu button",
            "AXMenu": "menu",
            "AXDockItem": "dock item",
            "AXWebArea": "web content",
            "AXHeading": "heading",
            "AXProgressIndicator": "progress bar",
            "AXColorWell": "color picker",
            "AXDisclosureTriangle": "disclosure",
            "AXIncrementor": "stepper",
        ]
        return map[role] ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    private func firstNonEmpty(_ strings: String...) -> String {
        strings.first { !$0.isEmpty } ?? ""
    }

    private func truncated(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "…"
    }

    private func resolvedElementFrame(for element: AXUIElement) -> CGRect? {
        let (primary, _) = resolveElement(element)
        return frame(of: primary) ?? frame(of: element)
    }

    private func focusedWindowFrame(for pid: pid_t) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let focusedWindowValue = axValue(appElement, key: kAXFocusedWindowAttribute) else {
            return nil
        }
        let focusedWindow = focusedWindowValue as! AXUIElement
        return frame(of: focusedWindow)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        if let positionValue = axValue(element, key: kAXPositionAttribute),
           let sizeValue = axValue(element, key: kAXSizeAttribute) {
            let pointValue = positionValue as! AXValue
            let sizeAXValue = sizeValue as! AXValue
            var position = CGPoint.zero
            var size = CGSize.zero
            let hasPosition = AXValueGetType(pointValue) == .cgPoint
                && AXValueGetValue(pointValue, .cgPoint, &position)
            let hasSize = AXValueGetType(sizeAXValue) == .cgSize
                && AXValueGetValue(sizeAXValue, .cgSize, &size)

            if hasPosition && hasSize && size.width > 0 && size.height > 0 {
                return CGRect(origin: position, size: size)
            }
        }

        return nil
    }

    private func axValue(_ element: AXUIElement, key: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value
    }
}
