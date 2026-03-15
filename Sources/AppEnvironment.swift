import Foundation

func resolveClaudeBinaryPath() -> String? {
    let candidates = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        NSHomeDirectory() + "/.local/bin/claude"
    ]

    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }

    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/bin/zsh")
    which.arguments = ["-lc", "which claude"]

    let pipe = Pipe()
    which.standardOutput = pipe

    try? which.run()
    which.waitUntilExit()

    let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if let path = result, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
        return path
    }

    return nil
}
