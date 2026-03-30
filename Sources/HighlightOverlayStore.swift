import AppKit
import Combine

final class HighlightOverlayStore: ObservableObject {
    @Published var highlightFrame: CGRect?

    /// Direct callbacks for CALayer-based windows (bypasses SwiftUI/Combine overhead)
    var onFrameChanged: ((CGRect?) -> Void)?

    func update(frame: CGRect?) {
        highlightFrame = frame
        onFrameChanged?(frame)
    }

    func clear() {
        highlightFrame = nil
        onFrameChanged?(nil)
    }
}
