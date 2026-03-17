import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Combine
import Speech

struct AutomationApp: Identifiable {
    let name: String
    let bundleIdentifier: String
    let icon: NSImage?
    let isGranted: Bool
    let isRunning: Bool

    var id: String { bundleIdentifier }
}

final class OnboardingViewModel: ObservableObject {
    @Published var currentStep = 0
    @Published var invokeHotKey = InvokeHotKey.stored() {
        didSet {
            guard oldValue != invokeHotKey else { return }
            invokeHotKey.persist()
        }
    }
    @Published var isClaudeInstalled = false
    @Published var isAccessibilityGranted = false
    @Published var isScreenRecordingGranted = false
    @Published var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var automationApps: [AutomationApp] = []
    @Published var automationSearchQuery = ""
    @Published var isLoadingAutomationApps = false

    private let onFinish: () -> Void
    private let onAccessibilityGranted: () -> Void

    init(
        onFinish: @escaping () -> Void,
        onAccessibilityGranted: @escaping () -> Void
    ) {
        self.onFinish = onFinish
        self.onAccessibilityGranted = onAccessibilityGranted
        refresh()
    }

    var coreRequirementsReady: Bool {
        isClaudeInstalled && isAccessibilityGranted && isScreenRecordingGranted
    }

    var hasAutomationTargets: Bool {
        !automationApps.isEmpty
    }

    var filteredAutomationApps: [AutomationApp] {
        let query = automationSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return automationApps }

        return automationApps.filter { app in
            app.name.localizedCaseInsensitiveContains(query) ||
            app.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    func refresh() {
        invokeHotKey = InvokeHotKey.stored()
        isClaudeInstalled = resolveClaudeBinaryPath() != nil
        isAccessibilityGranted = AXIsProcessTrusted()
        isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        refreshAutomationApps()
    }

    func finish() {
        onFinish()
    }

    func nextStep() {
        currentStep = min(currentStep + 1, 3)
    }

    func previousStep() {
        currentStep = max(currentStep - 1, 0)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refresh()
            if self.isAccessibilityGranted {
                self.onAccessibilityGranted()
            }
        }
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openSettings(anchor: "Privacy_ScreenCapture")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refresh()
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                self.refresh()
            }
        }
    }

    func requestSpeechRecognition() {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async {
                self.refresh()
            }
        }
    }

    func requestAutomation(for app: AutomationApp) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.automationPermissionGranted(for: app.bundleIdentifier, askUserIfNeeded: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.refreshAutomationApps()
            }
        }
    }

    func openAccessibilitySettings() {
        openSettings(anchor: "Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openSettings(anchor: "Privacy_ScreenCapture")
    }

    func openAutomationSettings() {
        openSettings(anchor: "Privacy_Automation")
    }

    func openMicrophoneSettings() {
        openSettings(anchor: "Privacy_Microphone")
    }

    func openSpeechSettings() {
        openSettings(anchor: "Privacy_SpeechRecognition")
    }

    func openClaudeInstallGuide() {
        guard let url = URL(string: "https://github.com/anthropics/claude-code") else { return }
        NSWorkspace.shared.open(url)
    }

    func statusLabel(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Ready"
        case .denied, .restricted:
            return "Needs System Settings"
        case .notDetermined:
            return "Needs Approval"
        @unknown default:
            return "Unknown"
        }
    }

    func statusLabel(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Ready"
        case .denied, .restricted:
            return "Needs System Settings"
        case .notDetermined:
            return "Needs Approval"
        @unknown default:
            return "Unknown"
        }
    }

    private func refreshAutomationApps() {
        isLoadingAutomationApps = true

        DispatchQueue.global(qos: .userInitiated).async {
            let apps = self.discoverInstalledApps()

            DispatchQueue.main.async {
                self.automationApps = apps
                self.isLoadingAutomationApps = false
            }

            // Check permissions in the background after the list is visible
            self.resolvePermissionsInBackground(for: apps)
        }
    }

    private func resolvePermissionsInBackground(for apps: [AutomationApp]) {
        DispatchQueue.global(qos: .utility).async {
            var updated: [AutomationApp] = []
            for app in apps {
                let granted = self.automationPermissionGranted(for: app.bundleIdentifier, askUserIfNeeded: false)
                updated.append(AutomationApp(
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    icon: app.icon,
                    isGranted: granted,
                    isRunning: app.isRunning
                ))
            }

            DispatchQueue.main.async {
                self.automationApps = updated
            }
        }
    }

    private func discoverInstalledApps() -> [AutomationApp] {
        let fileManager = FileManager.default
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let runningBundleURLs = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        let appRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
        ]

        var results: [String: AutomationApp] = [:]
        var visitedPaths = Set<String>()

        for root in appRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                visitedPaths.insert(url.path)

                if let app = automationApp(at: url, runningBundleIdentifiers: runningBundleIdentifiers) {
                    results[app.bundleIdentifier] = app
                }
            }
        }

        for url in runningBundleURLs where !visitedPaths.contains(url.path) {
            if let app = automationApp(at: url, runningBundleIdentifiers: runningBundleIdentifiers) {
                results[app.bundleIdentifier] = app
            }
        }

        return results.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func automationApp(at url: URL, runningBundleIdentifiers: Set<String>) -> AutomationApp? {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ??
            url.deletingPathExtension().lastPathComponent

        let icon = NSWorkspace.shared.icon(forFile: url.path)

        return AutomationApp(
            name: name,
            bundleIdentifier: bundleIdentifier,
            icon: icon,
            isGranted: false,
            isRunning: runningBundleIdentifiers.contains(bundleIdentifier)
        )
    }

    private func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func automationPermissionGranted(for bundleIdentifier: String, askUserIfNeeded: Bool) -> Bool {
        let bundDescType: OSType = 0x62756E64
        return bundleIdentifier.withCString { cString in
            var targetDesc = AEDesc()
            guard AECreateDesc(bundDescType, cString, bundleIdentifier.utf8.count, &targetDesc) == noErr else {
                return false
            }

            defer { AEDisposeDesc(&targetDesc) }

            let wildcard: OSType = 0x2A2A2A2A
            let status = AEDeterminePermissionToAutomateTarget(
                &targetDesc,
                wildcard,
                wildcard,
                askUserIfNeeded
            )

            return status == noErr
        }
    }
}
