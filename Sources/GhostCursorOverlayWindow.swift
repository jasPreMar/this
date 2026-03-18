import AppKit
import SwiftUI

final class GhostCursorOverlayCoordinator {
    private let store: GhostCursorStore
    private var windows: [ObjectIdentifier: GhostCursorOverlayWindow] = [:]
    private var screenObserver: NSObjectProtocol?

    init(store: GhostCursorStore) {
        self.store = store
        rebuildWindows()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildWindows()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func rebuildWindows() {
        let screens = NSScreen.screens
        var activeKeys = Set<ObjectIdentifier>()

        for screen in screens {
            let key = ObjectIdentifier(screen)
            activeKeys.insert(key)

            if let existingWindow = windows[key] {
                existingWindow.update(screen: screen)
                existingWindow.orderFrontRegardless()
            } else {
                let window = GhostCursorOverlayWindow(screen: screen, store: store)
                windows[key] = window
                window.orderFrontRegardless()
            }
        }

        let obsoleteKeys = windows.keys.filter { !activeKeys.contains($0) }
        for key in obsoleteKeys {
            windows[key]?.close()
            windows.removeValue(forKey: key)
        }
    }
}

private final class GhostCursorOverlayWindow: NSWindow {
    private let hostingView: NSHostingView<GhostCursorOverlayView>

    init(screen: NSScreen, store: GhostCursorStore) {
        self.hostingView = NSHostingView(
            rootView: GhostCursorOverlayView(store: store, screenFrame: screen.frame)
        )

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = hostingView
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(screen: NSScreen) {
        setFrame(screen.frame, display: true)
        hostingView.rootView = GhostCursorOverlayView(store: hostingView.rootView.store, screenFrame: screen.frame)
    }
}
