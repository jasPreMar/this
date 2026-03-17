import AppKit

/// Preloads PTT chime sounds into memory so playback is instantaneous.
class PTTSoundPlayer {
    private let pressSound: NSSound?
    private let releaseSound: NSSound?

    init() {
        pressSound = Self.loadSound(named: "C5")
        releaseSound = Self.loadSound(named: "A4")
    }

    func playPress() {
        guard let s = pressSound else { return }
        s.stop()
        s.play()
    }

    func playRelease() {
        guard let s = releaseSound else { return }
        s.stop()
        s.play()
    }

    private static func loadSound(named name: String) -> NSSound? {
        if let url = Bundle.module.url(forResource: name, withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: false)
        }
        return nil
    }
}
