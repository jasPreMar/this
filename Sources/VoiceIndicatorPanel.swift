import AppKit
import SwiftUI

struct VoiceIndicatorContentView: View {
    let voiceLevel: CGFloat
    let isPinnedMode: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        PanelChrome(cornerRadius: 16, usesNativeGlassSurface: NativeGlass.isSupported) {
            HStack(spacing: 8) {
                if isPinnedMode {
                    VoiceIndicatorButton(
                        systemName: "xmark",
                        filled: false,
                        action: onCancel
                    )
                }

                CompactVoiceWaveformView(level: voiceLevel)

                if isPinnedMode {
                    VoiceIndicatorButton(
                        systemName: "arrow.up",
                        filled: true,
                        action: onSend
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

private struct VoiceIndicatorButton: View {
    let systemName: String
    let filled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(filled ? .white : (isHovering ? .primary : .secondary))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        filled
                            ? Color.accentColor
                            : Color.primary.opacity(isHovering ? 0.1 : 0)
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

class VoiceIndicatorPanel: NSPanel {
    private var hostingView: NSHostingView<VoiceIndicatorContentView>!
    private var glassEffectView: NSView?
    private var voiceLevel: CGFloat = 0
    private var isPinnedMode: Bool = false
    private var onCancel: () -> Void = {}
    private var onSend: () -> Void = {}
    var onHoverChange: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var panelTrackingArea: NSTrackingArea?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        rebuildHostingView()
        installGlassSurface()
    }

    func update(voiceLevel: CGFloat, isPinnedMode: Bool, onCancel: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.voiceLevel = voiceLevel
        self.isPinnedMode = isPinnedMode
        self.onCancel = onCancel
        self.onSend = onSend
        rebuildHostingView()
        restoreGlassSurface()
        positionAtBottomCenter()
        updateTrackingArea()
    }

    func showPanel() {
        positionAtBottomCenter()
        orderFront(nil)
        updateTrackingArea()
    }

    func hidePanel() {
        if isHovered {
            isHovered = false
            onHoverChange?(false)
        }
        orderOut(nil)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isPinnedMode else { return }
        isHovered = true
        onHoverChange?(true)
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered else { return }
        isHovered = false
        onHoverChange?(false)
        NSCursor.pop()
    }

    private func rebuildHostingView() {
        let content = VoiceIndicatorContentView(
            voiceLevel: voiceLevel,
            isPinnedMode: isPinnedMode,
            onCancel: onCancel,
            onSend: onSend
        )
        if hostingView == nil {
            hostingView = NSHostingView(rootView: content)
        } else {
            hostingView.rootView = content
        }
        hostingView.invalidateIntrinsicContentSize()
    }

    private func installGlassSurface() {
        glassEffectView = NativeGlass.makeView(cornerRadius: 16)
        restoreGlassSurface()
    }

    private func restoreGlassSurface() {
        if let glass = glassEffectView {
            NativeGlass.attach(contentView: hostingView, to: glass)
            contentView = glass
        } else {
            contentView = hostingView
        }
    }

    private func updateTrackingArea() {
        guard let content = contentView else { return }
        if let existing = panelTrackingArea {
            content.removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: content.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        content.addTrackingArea(area)
        panelTrackingArea = area
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let fittingSize = hostingView.fittingSize
        setContentSize(fittingSize)
        let x = screen.visibleFrame.midX - fittingSize.width / 2
        let y = screen.visibleFrame.minY + 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
