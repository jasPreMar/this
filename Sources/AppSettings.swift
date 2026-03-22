import Combine
import Foundation

enum ClaudeModelPreset: String, CaseIterable, Identifiable {
    case sonnet46 = "sonnet"
    case opus46 = "opus"
    case opus461M = "opus[1m]"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonnet46:
            return "Sonnet 4.6"
        case .opus46:
            return "Opus 4.6"
        case .opus461M:
            return "Opus 4.6 1M"
        }
    }
}

enum AppSettings {
    private enum Keys {
        static let chimeEnabled = "chimeEnabled"
        static let autoVoiceEnabled = "autoVoiceEnabled"
        static let defaultModel = "defaultClaudeModel"
        static let thinkingEnabled = "defaultClaudeThinkingEnabled"
        static let fastModeEnabled = "defaultClaudeFastModeEnabled"
        static let ghostCursorEnabled = "ghostCursorEnabled"
        static let ghostCursorClickSoundEnabled = "ghostCursorClickSoundEnabled"
        static let ghostCursorDebugLabelsEnabled = "ghostCursorDebugLabelsEnabled"
        static let structuredUIEnabled = "structuredUIEnabled"
        static let hoverLoggingEnabled = "hoverLoggingEnabled"
        static let hoverLoggingDwellDelay = "hoverLoggingDwellDelay"
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Keys.chimeEnabled: true,
            Keys.autoVoiceEnabled: true,
            Keys.defaultModel: ClaudeModelPreset.sonnet46.rawValue,
            Keys.thinkingEnabled: false,
            Keys.fastModeEnabled: true,
            Keys.ghostCursorEnabled: true,
            Keys.ghostCursorClickSoundEnabled: false,
            Keys.ghostCursorDebugLabelsEnabled: false,
            Keys.structuredUIEnabled: false,
            Keys.hoverLoggingEnabled: true,
            Keys.hoverLoggingDwellDelay: 0.25,
        ])
    }

    static var invokeHotKey: InvokeHotKey {
        get { InvokeHotKey.stored() }
        set { newValue.persist() }
    }

    static var chimeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.chimeEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.chimeEnabled) }
    }

    static var autoVoiceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.autoVoiceEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoVoiceEnabled) }
    }

    static var defaultModel: ClaudeModelPreset {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: Keys.defaultModel),
                  let model = ClaudeModelPreset(rawValue: rawValue) else {
                return .sonnet46
            }
            return model
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.defaultModel)
        }
    }

    static var thinkingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.thinkingEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.thinkingEnabled) }
    }

    static var fastModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.fastModeEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.fastModeEnabled) }
    }

    static var ghostCursorEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.ghostCursorEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.ghostCursorEnabled) }
    }

    static var ghostCursorClickSoundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.ghostCursorClickSoundEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.ghostCursorClickSoundEnabled) }
    }

    static var ghostCursorDebugLabelsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.ghostCursorDebugLabelsEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.ghostCursorDebugLabelsEnabled) }
    }

    static var structuredUIEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.structuredUIEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.structuredUIEnabled) }
    }

    static var hoverLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hoverLoggingEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hoverLoggingEnabled) }
    }

    static var hoverLoggingDwellDelay: Double {
        get {
            let value = UserDefaults.standard.double(forKey: Keys.hoverLoggingDwellDelay)
            return value > 0 ? value : 0.25
        }
        set {
            UserDefaults.standard.set(max(0.05, newValue), forKey: Keys.hoverLoggingDwellDelay)
        }
    }

    static var claudeThinkingMode: String {
        thinkingEnabled ? "enabled" : "disabled"
    }

    static var claudeSettingsJSONString: String {
        let payload: [String: Any] = [
            "fastMode": fastModeEnabled,
            "fastModePerSessionOptIn": false,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"fastMode":false,"fastModePerSessionOptIn":false}"#
        }

        return string
    }
}

final class AppSettingsStore: ObservableObject {
    @Published var invokeHotKey: InvokeHotKey {
        didSet { AppSettings.invokeHotKey = invokeHotKey }
    }
    @Published var chimeEnabled: Bool {
        didSet { AppSettings.chimeEnabled = chimeEnabled }
    }
    @Published var autoVoiceEnabled: Bool {
        didSet { AppSettings.autoVoiceEnabled = autoVoiceEnabled }
    }
    @Published var defaultModel: ClaudeModelPreset {
        didSet { AppSettings.defaultModel = defaultModel }
    }
    @Published var thinkingEnabled: Bool {
        didSet { AppSettings.thinkingEnabled = thinkingEnabled }
    }
    @Published var fastModeEnabled: Bool {
        didSet { AppSettings.fastModeEnabled = fastModeEnabled }
    }
    @Published var ghostCursorEnabled: Bool {
        didSet { AppSettings.ghostCursorEnabled = ghostCursorEnabled }
    }
    @Published var ghostCursorClickSoundEnabled: Bool {
        didSet { AppSettings.ghostCursorClickSoundEnabled = ghostCursorClickSoundEnabled }
    }
    @Published var ghostCursorDebugLabelsEnabled: Bool {
        didSet { AppSettings.ghostCursorDebugLabelsEnabled = ghostCursorDebugLabelsEnabled }
    }
    @Published var structuredUIEnabled: Bool {
        didSet { AppSettings.structuredUIEnabled = structuredUIEnabled }
    }

    init() {
        AppSettings.registerDefaults()
        invokeHotKey = AppSettings.invokeHotKey
        chimeEnabled = AppSettings.chimeEnabled
        autoVoiceEnabled = AppSettings.autoVoiceEnabled
        defaultModel = AppSettings.defaultModel
        thinkingEnabled = AppSettings.thinkingEnabled
        fastModeEnabled = AppSettings.fastModeEnabled
        ghostCursorEnabled = AppSettings.ghostCursorEnabled
        ghostCursorClickSoundEnabled = AppSettings.ghostCursorClickSoundEnabled
        ghostCursorDebugLabelsEnabled = AppSettings.ghostCursorDebugLabelsEnabled
        structuredUIEnabled = AppSettings.structuredUIEnabled
    }
}
