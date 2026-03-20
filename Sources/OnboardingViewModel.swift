import AppKit
import AVFoundation
import Carbon
import Contacts
import EventKit
import Speech

enum ClaudeSetupChoice {
    case thisMac
    case later
}

enum PermissionResumeDestination: String {
    case onboarding
    case settingsPermissions
}

private enum PendingPermissionRequest: String {
    case screenRecording
    case microphone
    case speechRecognition
    case contacts
    case calendars
    case reminders
    case inputMonitoring
}

final class OnboardingViewModel: ObservableObject {
    private static let currentStepKey = "onboardingCurrentStep"
    let soundPlayer = PTTSoundPlayer()
    private static let lastStepIndex = 3
    private static let resumeOnLaunchKey = "resumeOnboardingOnLaunch"
    private static let resumeDestinationKey = "resumeOnboardingDestination"
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
    @Published var contactsStatus: CNAuthorizationStatus = .notDetermined
    @Published var calendarsStatus: EKAuthorizationStatus = .notDetermined
    @Published var remindersStatus: EKAuthorizationStatus = .notDetermined
    @Published var isInputMonitoringGranted = false
    @Published var claudeSetupChoice: ClaudeSetupChoice = .thisMac
    @Published private(set) var isAccessibilityRequestInFlight = false
    @Published private(set) var isScreenRecordingRequestInFlight = false
    @Published private(set) var isMicrophoneRequestInFlight = false
    @Published private(set) var isSpeechRecognitionRequestInFlight = false
    @Published private(set) var isContactsRequestInFlight = false
    @Published private(set) var isCalendarsRequestInFlight = false
    @Published private(set) var isRemindersRequestInFlight = false
    @Published private(set) var isInputMonitoringRequestInFlight = false
    @Published private(set) var isPreparingAppBundle = false

    private let onFinish: () -> Void
    private let onAccessibilityStateChange: (Bool) -> Void
    private let eventStore = EKEventStore()
    private var permissionPollTimer: Timer?
    private var deferredPermissionRefreshes: [DispatchWorkItem] = []
    private var appObservers: [NSObjectProtocol] = []
    private var isRefreshingPermissionState = false
    private var appBundlePreparationProcess: Process?

    init(
        onFinish: @escaping () -> Void,
        onAccessibilityStateChange: @escaping (Bool) -> Void
    ) {
        self.onFinish = onFinish
        self.onAccessibilityStateChange = onAccessibilityStateChange
        refreshWithSettling()
        startObservingSystemState()
        resumePendingPermissionRequestIfNeeded()
    }

    deinit {
        permissionPollTimer?.invalidate()
        deferredPermissionRefreshes.forEach { $0.cancel() }
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var coreRequirementsReady: Bool {
        isClaudeInstalled && isAccessibilityGranted && isScreenRecordingGranted
    }

    static var coreRequirementsReadyForCurrentSystem: Bool {
        resolveClaudeBinaryPath() != nil
            && currentAccessibilityGrantedForSystem()
            && CGPreflightScreenCaptureAccess()
    }

    var isMicrophoneGranted: Bool {
        microphoneStatus == .authorized
    }

    var isSpeechRecognitionGranted: Bool {
        speechStatus == .authorized
    }

    var isContactsGranted: Bool {
        contactsStatus == .authorized
    }

    var isCalendarsGranted: Bool {
        switch calendarsStatus {
        case .authorized, .fullAccess, .writeOnly:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    var isRemindersGranted: Bool {
        switch remindersStatus {
        case .authorized, .fullAccess, .writeOnly:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func refresh() {
        refreshStaticState()
        refreshPermissionState()
    }

    func refreshWithSettling() {
        refresh()
        scheduleDeferredPermissionRefreshes()
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

    func requestScreenRecording(resumeDestination: PermissionResumeDestination = .onboarding) {
        guard !isScreenRecordingRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.screenRecording, resumeDestination: resumeDestination) { return }
        isScreenRecordingRequestInFlight = true
        OnboardingViewModel.markResumeOnLaunch(destination: resumeDestination)
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

    func requestMicrophone(resumeDestination: PermissionResumeDestination = .onboarding) {
        guard !isMicrophoneRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.microphone, resumeDestination: resumeDestination) { return }

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

    func requestSpeechRecognition(resumeDestination: PermissionResumeDestination = .onboarding) {
        guard !isSpeechRecognitionRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.speechRecognition, resumeDestination: resumeDestination) { return }

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

    func requestContacts(resumeDestination: PermissionResumeDestination = .onboarding) {
        guard !isContactsRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.contacts, resumeDestination: resumeDestination) { return }

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            refreshPermissionState()
            return
        case .denied, .restricted:
            openContactsSettings()
            return
        case .notDetermined:
            break
        @unknown default:
            break
        }

        isContactsRequestInFlight = true
        NSApp.activate(ignoringOtherApps: true)

        CNContactStore().requestAccess(for: .contacts) { _, _ in
            DispatchQueue.main.async {
                self.isContactsRequestInFlight = false
                self.refreshPermissionState()
            }
        }
    }

    func requestCalendars(resumeDestination: PermissionResumeDestination = .onboarding) {
        guard !isCalendarsRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.calendars, resumeDestination: resumeDestination) { return }

        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess, .writeOnly:
            refreshPermissionState()
            return
        case .denied, .restricted:
            openCalendarsSettings()
            return
        case .notDetermined:
            break
        @unknown default:
            break
        }

        isCalendarsRequestInFlight = true
        NSApp.activate(ignoringOtherApps: true)

        eventStore.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async {
                self.isCalendarsRequestInFlight = false
                self.refreshPermissionState()
            }
        }
    }

    func requestReminders(resumeDestination: PermissionResumeDestination = .onboarding) {
        guard !isRemindersRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.reminders, resumeDestination: resumeDestination) { return }

        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized, .fullAccess, .writeOnly:
            refreshPermissionState()
            return
        case .denied, .restricted:
            openRemindersSettings()
            return
        case .notDetermined:
            break
        @unknown default:
            break
        }

        isRemindersRequestInFlight = true
        NSApp.activate(ignoringOtherApps: true)

        eventStore.requestFullAccessToReminders { _, _ in
            DispatchQueue.main.async {
                self.isRemindersRequestInFlight = false
                self.refreshPermissionState()
            }
        }
    }

    func requestInputMonitoring(resumeDestination: PermissionResumeDestination = .onboarding) {
        guard !isInputMonitoringRequestInFlight else { return }
        if prepareAppBundleForSensitivePermissionIfNeeded(.inputMonitoring, resumeDestination: resumeDestination) { return }

        if #available(macOS 10.15, *) {
            if CGPreflightListenEventAccess() {
                refreshPermissionState()
                return
            }
        } else {
            refreshPermissionState()
            return
        }

        isInputMonitoringRequestInFlight = true
        OnboardingViewModel.markResumeOnLaunch(destination: resumeDestination)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.global(qos: .userInitiated).async {
            let granted: Bool
            if #available(macOS 10.15, *) {
                granted = CGRequestListenEventAccess()
            } else {
                granted = true
            }

            DispatchQueue.main.async {
                self.isInputMonitoringRequestInFlight = false
                self.refreshPermissionState()

                if !granted && !self.isInputMonitoringGranted {
                    self.openInputMonitoringSettings()
                }
            }
        }
    }

    func openAccessibilitySettings() {
        openSettings(anchor: "Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openSettings(anchor: "Privacy_ScreenCapture")
    }

    func openMicrophoneSettings() {
        openSettings(anchor: "Privacy_Microphone")
    }

    func openSpeechSettings() {
        openSettings(anchor: "Privacy_SpeechRecognition")
    }

    func openCalendarsSettings() {
        openSettings(anchor: "Privacy_Calendars")
    }

    func openContactsSettings() {
        openSettings(anchor: "Privacy_Contacts")
    }

    func openFullDiskAccessSettings() {
        openSettings(anchor: "Privacy_AllFiles")
    }

    func openRemindersSettings() {
        openSettings(anchor: "Privacy_Reminders")
    }

    func openAppManagementSettings() {
        openSettings(anchor: "Privacy_AppBundles")
    }

    func openInputMonitoringSettings() {
        openSettings(anchor: "Privacy_ListenEvent")
    }

    func openClaudeInstallGuide() {
        guard let url = URL(string: "https://github.com/anthropics/claude-code") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestClaudeInstall() {
        guard !isClaudeInstalled else { return }
        openClaudeInstallGuide()
    }

    private func prepareAppBundleAndRelaunch(
        pendingPermission: PendingPermissionRequest? = nil,
        resumeDestination: PermissionResumeDestination
    ) {
        guard !isPreparingAppBundle else { return }

        if let pendingPermission {
            OnboardingViewModel.storePendingPermissionRequest(pendingPermission)
        }
        OnboardingViewModel.markResumeOnLaunch(destination: resumeDestination)

        guard let workspaceRoot = resolveWorkspaceRoot() else {
            OnboardingViewModel.clearPendingPermissionRequest()
            OnboardingViewModel.clearResumeOnLaunch()
            showAppBundlePreparationFailure(
                message: "Could not locate the package root needed to build HyperPointer.app."
            )
            return
        }

        let scriptURL = workspaceRoot.appendingPathComponent("scripts/dev-app.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            OnboardingViewModel.clearPendingPermissionRequest()
            OnboardingViewModel.clearResumeOnLaunch()
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
                    OnboardingViewModel.clearResumeOnLaunch()
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
            OnboardingViewModel.clearResumeOnLaunch()
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
        update(\.contactsStatus, to: CNContactStore.authorizationStatus(for: .contacts))
        update(\.calendarsStatus, to: EKEventStore.authorizationStatus(for: .event))
        update(\.remindersStatus, to: EKEventStore.authorizationStatus(for: .reminder))
        if #available(macOS 10.15, *) {
            update(\.isInputMonitoringGranted, to: CGPreflightListenEventAccess())
        } else {
            update(\.isInputMonitoringGranted, to: true)
        }

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
                self?.refreshWithSettling()
            }
        ]

    }

    private func scheduleDeferredPermissionRefreshes() {
        deferredPermissionRefreshes.forEach { $0.cancel() }
        deferredPermissionRefreshes.removeAll()

        for delay in [0.25, 0.75, 1.5, 3.0] {
            let workItem = DispatchWorkItem { [weak self] in
                self?.refreshPermissionState()
            }
            deferredPermissionRefreshes.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
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

    static var resumeDestinationOnLaunch: PermissionResumeDestination? {
        guard UserDefaults.standard.bool(forKey: resumeOnLaunchKey) else {
            return nil
        }

        guard let rawValue = UserDefaults.standard.string(forKey: resumeDestinationKey),
              let destination = PermissionResumeDestination(rawValue: rawValue) else {
            return .onboarding
        }

        return destination
    }

    static func clearResumeOnLaunch() {
        UserDefaults.standard.removeObject(forKey: resumeOnLaunchKey)
        UserDefaults.standard.removeObject(forKey: resumeDestinationKey)
    }

    private static func markResumeOnLaunch(destination: PermissionResumeDestination) {
        UserDefaults.standard.set(true, forKey: resumeOnLaunchKey)
        UserDefaults.standard.set(destination.rawValue, forKey: resumeDestinationKey)
    }

    private func currentAccessibilityGranted() -> Bool {
        Self.currentAccessibilityGrantedForSystem()
    }

    private static func currentAccessibilityGrantedForSystem() -> Bool {
        let options = [accessibilityPromptKey: false] as CFDictionary
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
    private func prepareAppBundleForSensitivePermissionIfNeeded(
        _ permission: PendingPermissionRequest,
        resumeDestination: PermissionResumeDestination
    ) -> Bool {
        guard !isRunningFromAppBundle else { return false }
        prepareAppBundleAndRelaunch(
            pendingPermission: permission,
            resumeDestination: resumeDestination
        )
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
            case .contacts:
                self.requestContacts()
            case .calendars:
                self.requestCalendars()
            case .reminders:
                self.requestReminders()
            case .inputMonitoring:
                self.requestInputMonitoring()
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
