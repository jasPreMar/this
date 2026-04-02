import AppKit

final class HighlightOverlayCoordinator {
    private let store: HighlightOverlayStore
    private var windows: [ObjectIdentifier: HighlightOverlayWindow] = [:]
    private var observers: [NSObjectProtocol] = []

    init(store: HighlightOverlayStore) {
        self.store = store
        rebuildWindows()

        store.onFrameChanged = { [weak self] frame in
            self?.updateAllHighlights(frame: frame)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildWindows()
        })

        // Rebuild overlay windows when Spaces change (e.g. entering/exiting fullscreen)
        // Screen identities can change, so rebuild rather than just reorder.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildWindows()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func rebuildWindows() {
        let screens = NSScreen.screens
        var activeKeys = Set<ObjectIdentifier>()

        for screen in screens {
            let key = ObjectIdentifier(screen)
            activeKeys.insert(key)

            if let existingWindow = windows[key] {
                existingWindow.updateScreen(screen)
                existingWindow.orderFrontRegardless()
            } else {
                let window = HighlightOverlayWindow(screen: screen)
                windows[key] = window
                window.orderFrontRegardless()
            }
        }

        let obsoleteKeys = windows.keys.filter { !activeKeys.contains($0) }
        for key in obsoleteKeys {
            windows[key]?.close()
            windows.removeValue(forKey: key)
        }

        // Apply current frame to all windows
        updateAllHighlights(frame: store.highlightFrame)
    }

    private func updateAllHighlights(frame: CGRect?) {
        for window in windows.values {
            window.updateHighlight(frame: frame)
            if frame != nil {
                window.orderFrontRegardless()
            }
        }
    }
}

private final class HighlightOverlayWindow: NSWindow {
    private let highlightLayer = CALayer()
    private let borderLayer = CALayer()
    private var screenFrame: CGRect

    init(screen: NSScreen) {
        self.screenFrame = screen.frame

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let rootView = NSView(frame: screen.frame)
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = .clear
        contentView = rootView

        // Fill layer
        highlightLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        highlightLayer.cornerRadius = 4
        highlightLayer.isHidden = true
        rootView.layer?.addSublayer(highlightLayer)

        // Border layer
        borderLayer.backgroundColor = .clear
        borderLayer.borderColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        borderLayer.borderWidth = 2
        borderLayer.cornerRadius = 4
        borderLayer.shadowColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor
        borderLayer.shadowRadius = 6
        borderLayer.shadowOpacity = 1
        borderLayer.shadowOffset = .zero
        borderLayer.isHidden = true
        rootView.layer?.addSublayer(borderLayer)

        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updateScreen(_ screen: NSScreen) {
        screenFrame = screen.frame
        setFrame(screen.frame, display: true)
    }

    func updateHighlight(frame: CGRect?) {
        guard let frame else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.isHidden = true
            borderLayer.isHidden = true
            CATransaction.commit()
            return
        }

        guard screenFrame.intersects(frame) else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.isHidden = true
            borderLayer.isHidden = true
            CATransaction.commit()
            return
        }

        let localRect = localRect(for: frame)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = localRect
        highlightLayer.isHidden = false
        borderLayer.frame = localRect
        borderLayer.isHidden = false
        CATransaction.commit()
    }

    private func localRect(for globalRect: CGRect) -> CGRect {
        // AX coordinates use a desktop-wide top-left origin. Convert through the
        // union of all screen frames so vertically stacked and uneven displays map
        // back into the correct per-screen window coordinates.
        let desktopFrame = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }
        let desktopTop = desktopFrame.isNull ? screenFrame.maxY : desktopFrame.maxY
        let screenTopInAX = desktopTop - screenFrame.maxY
        let x = globalRect.origin.x - screenFrame.minX
        // Convert from AX top-down Y to CALayer bottom-up Y
        let axLocalY = globalRect.origin.y - screenTopInAX
        let y = screenFrame.height - axLocalY - globalRect.height
        return CGRect(x: x, y: y, width: globalRect.width, height: globalRect.height)
    }
}
