import AppKit

/// Preloads PTT chime sounds into memory so playback is instantaneous.
class PTTSoundPlayer {
    private static let resourceBundleName = "HyperPointer_HyperPointer"
    private let pressSound: NSSound?
    private let releaseSound: NSSound?
    private let ghostCursorClickSound: NSSound?

    init() {
        pressSound = Self.loadSound(named: "C5")
        releaseSound = Self.loadSound(named: "A4")
        ghostCursorClickSound = Self.loadSound(named: "A4")
        ghostCursorClickSound?.volume = 0.25
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

    func playGhostCursorClick() {
        guard let sound = ghostCursorClickSound else { return }
        sound.stop()
        sound.play()
    }

    private static func loadSound(named name: String) -> NSSound? {
        for url in resourceCandidateURLs(for: name, ext: "wav") {
            if let sound = NSSound(contentsOf: url, byReference: false) {
                return sound
            }
        }
        return nil
    }

    private static func resourceCandidateURLs(for name: String, ext: String) -> [URL] {
        var candidates: [URL] = []

        if let mainResourceURL = Bundle.main.resourceURL {
            candidates.append(mainResourceURL.appendingPathComponent("\(name).\(ext)"))
            candidates.append(
                mainResourceURL
                    .appendingPathComponent("\(resourceBundleName).bundle")
                    .appendingPathComponent("\(name).\(ext)")
            )
        }

        if let executableURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(
                executableURL
                    .appendingPathComponent("\(resourceBundleName).bundle")
                    .appendingPathComponent("\(name).\(ext)")
            )
        }

        var seen = Set<String>()
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }
}
