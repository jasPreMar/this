import AppKit
import Combine
import CoreGraphics

class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var hoveredApp: String = ""
    @Published var hoveredParts: [String] = []
    @Published var selectedText: String = ""
    @Published var isChatMode = false
    @Published var claudeManager: ClaudeProcessManager?
    @Published var chatHistory: [(role: String, text: String)] = []
    @Published var lastScreenshotStatus: String = ""
    var currentSessionId: String?
    private var hoveredAppPID: pid_t = 0

    /// Set by FloatingPanel
    var onSubmit: ((String, URL?, String) -> Void)?
    var onClose: (() -> Void)?

    func submitMessage() {
        let message = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        if isChatMode {
            // Follow-up message — resume the existing session
            chatHistory.append((role: "user", text: message))
            query = ""
            let manager = ClaudeProcessManager()
            manager.onComplete = { [weak self] response in
                // Clear streaming text before appending to history to avoid duplicate display
                manager.outputText = ""
                self?.chatHistory.append((role: "assistant", text: response))
                // Update session ID in case it changed
                if let sid = manager.sessionId {
                    self?.currentSessionId = sid
                }
            }
            claudeManager = manager
            manager.start(message: message, resumeSessionId: currentSessionId)
        } else {
            // First message — switch to chat mode
            let context = buildContextMessage()
            let (screenshotURL, screenshotStatus) = captureHoveredWindowScreenshot()
            lastScreenshotStatus = screenshotStatus
            onSubmit?(context, screenshotURL, screenshotStatus)
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
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return (nil, "Screenshot not captured: screen recording permission not granted")
        }

        let cgImage: CGImage?

        if hoveredAppPID == 0 {
            // No hovered element — capture the entire screen
            cgImage = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [])
        } else {
            guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
                return (nil, "Screenshot not captured: failed to enumerate windows")
            }

            let appWindows = windowList.filter {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == hoveredAppPID
            }

            let sortedWindows = appWindows.sorted {
                ($0[kCGWindowLayer as String] as? Int ?? 999) < ($1[kCGWindowLayer as String] as? Int ?? 999)
            }

            guard let topWindow = sortedWindows.first,
                  let windowID = topWindow[kCGWindowNumber as String] as? CGWindowID else {
                return (nil, "Screenshot not captured: no visible window for hovered app")
            }

            cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming])
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

    func updateHoveredApp() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.main else { return }
        let cgPoint = CGPoint(x: mouseLocation.x, y: screen.frame.height - mouseLocation.y)

        // Use Accessibility API to get the element under the cursor
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(cgPoint.x), Float(cgPoint.y), &element)

        guard result == .success, let element = element else {
            hoveredApp = ""
            return
        }

        // Store the PID of the hovered app for screenshot use
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let app = NSRunningApplication(processIdentifier: pid), app.localizedName != "HyperPointer" {
            hoveredAppPID = pid
        }

        // Build a description from the element hierarchy
        let description = describeElement(element)
        if hoveredApp != description {
            hoveredApp = description
            hoveredParts = description.isEmpty ? [] : description.components(separatedBy: " → ")
        }

        // Check for selected/highlighted text
        let sel = getSelectedText(element: element)
        if selectedText != sel {
            selectedText = sel
        }
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

        // Fall back to the container if we found one
        if let container = bestContainer {
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

    private func describeElement(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier ?? ""

        if appName == "HyperPointer" { return "" }

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

    private func axValue(_ element: AXUIElement, key: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value
    }
}
