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
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: false)
        }
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let url = execDir.appendingPathComponent("\(name).wav")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSSound(contentsOf: url, byReference: false)
    }
}
