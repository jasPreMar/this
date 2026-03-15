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

    var id: String { bundleIdentifier }
}

final class OnboardingViewModel: ObservableObject {
    @Published var currentStep = 0
    @Published var isClaudeInstalled = false
    @Published var isAccessibilityGranted = false
    @Published var isScreenRecordingGranted = false
    @Published var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var automationApps: [AutomationApp] = []

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

    func refresh() {
        isClaudeInstalled = resolveClaudeBinaryPath() != nil
        isAccessibilityGranted = AXIsProcessTrusted()
        isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        automationApps = loadAutomationApps()
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
        _ = automationPermissionGranted(for: app.bundleIdentifier, askUserIfNeeded: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.refresh()
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

    private func loadAutomationApps() -> [AutomationApp] {
        let apps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                ($0.bundleIdentifier?.isEmpty == false)
            }
            .compactMap { app -> AutomationApp? in
                guard let bundleIdentifier = app.bundleIdentifier else { return nil }
                return AutomationApp(
                    name: app.localizedName ?? bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    icon: app.icon,
                    isGranted: automationPermissionGranted(for: bundleIdentifier, askUserIfNeeded: false)
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        return Array(Dictionary(grouping: apps, by: \.bundleIdentifier).compactMap { $0.value.first })
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
