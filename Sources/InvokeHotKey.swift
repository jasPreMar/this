import AppKit

enum InvokeHotKey: String, CaseIterable, Identifiable {
    case function
    case command
    case option
    case control

    static let defaultsKey = "invokeHotKey"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .function:
            return "Fn"
        case .command:
            return "Command"
        case .option:
            return "Option"
        case .control:
            return "Control"
        }
    }

    var holdLabel: String {
        "Hold \(displayName.lowercased())"
    }

    var releaseLabel: String {
        "Release \(displayName.lowercased())"
    }

    var symbol: String {
        switch self {
        case .function:
            return "fn"
        case .command:
            return "\u{2318}"
        case .option:
            return "\u{2325}"
        case .control:
            return "\u{2303}"
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .function:
            return .function
        case .command:
            return .command
        case .option:
            return .option
        case .control:
            return .control
        }
    }

    func isPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(modifierFlag)
    }

    func persist(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    static func stored(in defaults: UserDefaults = .standard) -> InvokeHotKey {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let hotKey = InvokeHotKey(rawValue: rawValue) else {
            return .function
        }
        return hotKey
    }
}
