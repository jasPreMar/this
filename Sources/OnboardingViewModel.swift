import AppKit
import AVFoundation
import Carbon
import Speech

enum ClaudeSetupChoice {
    case thisMac
    case later
}

private enum PendingPermissionRequest: String {
    case screenRecording
    case microphone
    case speechRecognition
}

final class OnboardingViewModel: ObservableObject {
    private static let currentStepKey = "onboardingCurrentStep"
    let soundPlayer = PTTSoundPlayer()
    private static let lastStepIndex = 3
    private static let resumeOnLaunchKey = "resumeOnboardingOnLaunch"
    private static let pendingPermissionRequestKey = "pendingPermissionRequest"
    private static let accessibilityPromptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String

    @Published var currentStep = OnboardingViewModel.restoredCurrentStep() {
        didSet {
            UserDefaults.standard.set(currentStep, forKey: OnboardingViewModel.currentStepKey)
        }
    }
    @Published var invokeHotKey = InvokeHotKey.stored() {
        didSet {
            guard oldValue != invokeHotKey else { return }
            invokeHotKey.persist()
        }
    }
    @Published var chimeEnabled = UserDefaults.standard.bool(forKey: "chimeEnabled") {
        didSet {
            UserDefaults.standard.set(chimeEnabled, forKey: "chimeEnabled")
        }
    }
    @Published var isClaudeInstalled = false
    @Published var isAccessibilityGranted = false
    @Published var isScreenRecordingGranted = false
    @Published var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var claudeSetupChoice: ClaudeSetupChoice = .thisMac
    @Published private(set) var isAccessibilityRequestInFlight = false
    @Published private(set) var isScreenRecordingRequestInFlight = false
    @Published private(set) var isMicrophoneRequestInFlight = false
    @Published private(set) var isSpeechRecognitionRequestInFlight = false
    @Published private(set) var isPreparingAppBundle = false

    private let onFinish: () -> Void
    private let onAccessibilityStateChange: (Bool) -> Void
    private var permissionPollTimer: Timer?
    private var appObservers: [NSObjectProtocol] = []
    private var isRefreshingPermissionState = false
    private var appBundlePreparationProcess: Process?

    init(
        onFinish: @escaping () -> Void,
        onAccessibilityStateChange: @escaping (Bool) -> Void
    ) {
        self.onFinish = onFinish
        self.onAccessibilityStateChange = onAccessibilityStateChange
        refresh()
        startObservingSystemState()
        resumePendingPermissionRequestIfNeeded()
    }

    deinit {
        permissionPollTimer?.invalidate()
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var coreRequirementsReady: Bool {
        isClaudeInstalled && isAccessibilityGranted && isScreenRecordingGranted
    }

    var isMicrophoneGranted: Bool {
        microphoneStatus == .authorized
    }

    var isSpeechRecognitionGranted: Bool {
        speechStatus == .authorized
    }

    var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func refresh() {
        refreshStaticState()
        refreshPermissionState()
    }

    func finish() {
        UserDefaults.standard.removeObject(forKey: OnboardingViewModel.currentStepKey)
        OnboardingViewModel.clearResumeOnLaunch()
        onFinish()
    }

    func nextStep() {
        currentStep = min(currentStep + 1, Self.lastStepIndex)
    }

    func previousStep() {
        currentStep = max(currentStep - 1, 0)
    }

    func requestAccessibility() {
        guard !isAccessibilityRequestInFlight else { return }
        isAccessibilityRequestInFlight = true
        NSApp.activate(ignoringOtherApps: true)

        let options = [OnboardingViewModel.accessibilityPromptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isAccessibilityRequestInFlight = false
            self.refreshPermissionState()
        }
    }

    func requestScreenRecording() {
        guard !isScreenRecordingRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.screenRecording) { return }
        isScreenRecordingRequestInFlight = true
        OnboardingViewModel.markResumeOnLaunch()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.global(qos: .userInitiated).async {
            let granted = CGRequestScreenCaptureAccess()

            DispatchQueue.main.async {
                self.isScreenRecordingRequestInFlight = false
                self.refreshPermissionState()

                if !granted && !self.isScreenRecordingGranted {
                    self.openScreenRecordingSettings()
                }
            }
        }
    }

    func requestMicrophone() {
        guard !isMicrophoneRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.microphone) { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshPermissionState()
            return
        case .denied, .restricted:
            openMicrophoneSettings()
            return
        case .notDetermined:
            break
        @unknown default:
            break
        }

        isMicrophoneRequestInFlight = true
        NSApp.activate(ignoringOtherApps: true)

        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                self.isMicrophoneRequestInFlight = false
                self.refreshPermissionState()
            }
        }
    }

    func requestSpeechRecognition() {
        guard !isSpeechRecognitionRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.speechRecognition) { return }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            refreshPermissionState()
            return
        case .denied, .restricted:
            openSpeechSettings()
            return
        case .notDetermined:
            break
        @unknown default:
            break
        }

        isSpeechRecognitionRequestInFlight = true
        NSApp.activate(ignoringOtherApps: true)

        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async {
                self.isSpeechRecognitionRequestInFlight = false
                self.refreshPermissionState()
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

    func requestClaudeInstall() {
        guard !isClaudeInstalled else { return }
        openClaudeInstallGuide()
    }

    private func prepareAppBundleAndRelaunch(pendingPermission: PendingPermissionRequest? = nil) {
        guard !isPreparingAppBundle else { return }

        if let pendingPermission {
            OnboardingViewModel.storePendingPermissionRequest(pendingPermission)
        }

        guard let workspaceRoot = resolveWorkspaceRoot() else {
            OnboardingViewModel.clearPendingPermissionRequest()
            showAppBundlePreparationFailure(
                message: "Could not locate the package root needed to build HyperPointer.app."
            )
            return
        }

        let scriptURL = workspaceRoot.appendingPathComponent("scripts/dev-app.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            OnboardingViewModel.clearPendingPermissionRequest()
            showAppBundlePreparationFailure(
                message: "Missing executable packaging script at \(scriptURL.path)."
            )
            return
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.currentDirectoryURL = workspaceRoot
        process.arguments = ["-lc", "./scripts/dev-app.sh --run"]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { [weak self] finishedProcess in
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                guard let self else { return }
                self.appBundlePreparationProcess = nil
                self.isPreparingAppBundle = false

                guard finishedProcess.terminationStatus == 0 else {
                    OnboardingViewModel.clearPendingPermissionRequest()
                    self.showAppBundlePreparationFailure(
                        message: output.isEmpty ? "Building HyperPointer.app failed." : output
                    )
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
        }

        do {
            isPreparingAppBundle = true
            appBundlePreparationProcess = process
            try process.run()
        } catch {
            appBundlePreparationProcess = nil
            isPreparingAppBundle = false
            OnboardingViewModel.clearPendingPermissionRequest()
            showAppBundlePreparationFailure(message: error.localizedDescription)
        }
    }

    private func refreshPermissionState() {
        guard !isRefreshingPermissionState else { return }
        isRefreshingPermissionState = true
        defer { isRefreshingPermissionState = false }

        let previousAccessibilityGranted = isAccessibilityGranted
        let newAccessibilityGranted = currentAccessibilityGranted()

        update(\.isAccessibilityGranted, to: newAccessibilityGranted)
        update(\.isScreenRecordingGranted, to: CGPreflightScreenCaptureAccess())
        update(\.microphoneStatus, to: AVCaptureDevice.authorizationStatus(for: .audio))
        update(\.speechStatus, to: SFSpeechRecognizer.authorizationStatus())

        if previousAccessibilityGranted != newAccessibilityGranted {
            onAccessibilityStateChange(newAccessibilityGranted)
        }
    }

    private func startObservingSystemState() {
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refreshPermissionState()
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer

        appObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshStaticState()
                self?.refreshPermissionState()
            }
        ]

    }

    private func refreshStaticState() {
        update(\.invokeHotKey, to: InvokeHotKey.stored())
        update(\.isClaudeInstalled, to: resolveClaudeBinaryPath() != nil)
    }

    private func openSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }


    private static func restoredCurrentStep() -> Int {
        let storedStep = UserDefaults.standard.object(forKey: currentStepKey) as? Int ?? 0
        return max(0, min(storedStep, lastStepIndex))
    }

    static var shouldResumeOnLaunch: Bool {
        UserDefaults.standard.bool(forKey: resumeOnLaunchKey)
    }

    static func clearResumeOnLaunch() {
        UserDefaults.standard.removeObject(forKey: resumeOnLaunchKey)
    }

    private static func markResumeOnLaunch() {
        UserDefaults.standard.set(true, forKey: resumeOnLaunchKey)
    }

    private func currentAccessibilityGranted() -> Bool {
        let options = [OnboardingViewModel.accessibilityPromptKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func showAppBundlePreparationFailure(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not prepare HyperPointer.app"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func resolveWorkspaceRoot() -> URL? {
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ].compactMap { $0 }

        for candidate in candidates {
            if let root = findPackageRoot(startingAt: candidate) {
                return root
            }
        }

        return nil
    }

    private func findPackageRoot(startingAt startURL: URL) -> URL? {
        var currentURL = startURL
        let packageFileName = "Package.swift"

        while true {
            if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(packageFileName).path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return nil
            }
            currentURL = parentURL
        }
    }

    @discardableResult
    private func prepareAppBundleForSensitivePermissionIfNeeded(_ permission: PendingPermissionRequest) -> Bool {
        guard !isRunningFromAppBundle else { return false }
        prepareAppBundleAndRelaunch(pendingPermission: permission)
        return true
    }

    private func resumePendingPermissionRequestIfNeeded() {
        guard isRunningFromAppBundle,
              let pendingPermission = OnboardingViewModel.takePendingPermissionRequest() else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            switch pendingPermission {
            case .screenRecording:
                self.requestScreenRecording()
            case .microphone:
                self.requestMicrophone()
            case .speechRecognition:
                self.requestSpeechRecognition()
            }
        }
    }

    private static func storePendingPermissionRequest(_ request: PendingPermissionRequest) {
        UserDefaults.standard.set(request.rawValue, forKey: pendingPermissionRequestKey)
    }

    private static func clearPendingPermissionRequest() {
        UserDefaults.standard.removeObject(forKey: pendingPermissionRequestKey)
    }

    private static func takePendingPermissionRequest() -> PendingPermissionRequest? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingPermissionRequestKey) else {
            return nil
        }
        clearPendingPermissionRequest()
        return PendingPermissionRequest(rawValue: rawValue)
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<OnboardingViewModel, Value>, to newValue: Value) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }
}
