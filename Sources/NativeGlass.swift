import AppKit

enum NativeGlass {
    static var isSupported: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return NSClassFromString("NSGlassEffectView") != nil
    }

    static func makeView(cornerRadius: CGFloat) -> NSView? {
        guard isSupported,
              let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return nil
        }

        let glassView = glassClass.init(frame: .zero)
        glassView.autoresizingMask = [.width, .height]
        updateCornerRadius(cornerRadius, on: glassView)
        return glassView
    }

    static func attach(contentView: NSView, to glassView: NSView) {
        (glassView as NSObject).setValue(contentView, forKey: "contentView")
    }

    static func updateCornerRadius(_ cornerRadius: CGFloat, on glassView: NSView) {
        (glassView as NSObject).setValue(cornerRadius, forKey: "cornerRadius")
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = cornerRadius
        glassView.layer?.masksToBounds = true
        glassView.layer?.borderWidth = 0.5
        glassView.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        if #available(macOS 10.15, *) {
            glassView.layer?.cornerCurve = .continuous
        }
    }
}
