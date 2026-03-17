import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    private let steps = [
        "Welcome",
        "Permissions",
        "Automation",
        "Try it"
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }

            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HyperPointer")
                .font(.system(size: 20, weight: .semibold))

            Text("Alpha setup")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                    Button {
                        viewModel.currentStep = index
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(index == viewModel.currentStep ? Color.accentColor : Color.secondary.opacity(0.12))
                                .foregroundStyle(index == viewModel.currentStep ? Color.white : Color.primary)
                                .clipShape(Circle())

                            Text(title)
                                .font(.system(size: 13, weight: index == viewModel.currentStep ? .semibold : .regular))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(index == viewModel.currentStep ? Color.accentColor.opacity(0.1) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                SummaryBadge(
                    title: "Claude CLI",
                    value: viewModel.isClaudeInstalled ? "Ready" : "Missing",
                    isReady: viewModel.isClaudeInstalled
                )
                SummaryBadge(
                    title: "Core Permissions",
                    value: viewModel.coreRequirementsReady ? "Ready" : "Needs setup",
                    isReady: viewModel.coreRequirementsReady
                )
                SummaryBadge(
                    title: "Automation Apps",
                    value: viewModel.hasAutomationTargets ? "\(viewModel.automationApps.count) found" : "Scanning installed apps",
                    isReady: viewModel.hasAutomationTargets
                )
            }
        }
        .padding(20)
        .frame(width: 220, alignment: .topLeading)
        .background(Color.black.opacity(0.02))
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.currentStep {
        case 0:
            WelcomeStep(viewModel: viewModel)
        case 1:
            PermissionsStep(viewModel: viewModel)
        case 2:
            AutomationStep(viewModel: viewModel)
        default:
            FinishStep(viewModel: viewModel)
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip for now") {
                viewModel.finish()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            if viewModel.currentStep > 0 {
                Button("Back") {
                    viewModel.previousStep()
                }
            }

            Button(viewModel.currentStep == steps.count - 1 ? "Finish Setup" : "Next") {
                if viewModel.currentStep == steps.count - 1 {
                    viewModel.finish()
                } else {
                    viewModel.nextStep()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct WelcomeStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Get HyperPointer ready")
                    .font(.system(size: 30, weight: .semibold))

                Text("This alpha works best when Claude CLI is installed, the core permissions are granted, and the apps you want to control are pre-approved for Automation.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                setupBlock(
                    title: "What the wizard does",
                    body: "It walks through the minimum setup needed to point at something on screen, ask HyperPointer to act on it, and avoid surprise permission prompts in the middle of a task."
                )

                setupBlock(
                    title: "What is required now",
                    body: "Claude CLI, Accessibility, and Screen Recording are the core pieces. Microphone and Speech Recognition are only needed for command-held voice input."
                )

                HStack(spacing: 12) {
                    statusTile(title: "Claude CLI", subtitle: viewModel.isClaudeInstalled ? "Installed" : "Install before using chat", isReady: viewModel.isClaudeInstalled)
                    statusTile(title: "Core access", subtitle: viewModel.coreRequirementsReady ? "Ready to test" : "Needs setup", isReady: viewModel.coreRequirementsReady)
                }
            }
            .padding(28)
        }
    }

    private func setupBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func statusTile(title: String, subtitle: String, isReady: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupStatusPill(text: isReady ? "Ready" : "Needs setup", isReady: isReady)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct PermissionsStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Permissions and prerequisites")
                    .font(.system(size: 28, weight: .semibold))

                Text("Grant the core access first. HyperPointer uses these to read what is under your cursor, capture the window you are looking at, and send your prompt to Claude.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PermissionRow(
                    title: "Claude CLI",
                    description: "HyperPointer shells out to Claude for every conversation. Install the CLI before testing the app.",
                    statusText: viewModel.isClaudeInstalled ? "Ready" : "Missing",
                    isReady: viewModel.isClaudeInstalled,
                    primaryTitle: viewModel.isClaudeInstalled ? "Refresh" : "Install Claude",
                    secondaryTitle: viewModel.isClaudeInstalled ? nil : "Refresh",
                    primaryAction: {
                        if viewModel.isClaudeInstalled {
                            viewModel.refresh()
                        } else {
                            viewModel.openClaudeInstallGuide()
                        }
                    },
                    secondaryAction: viewModel.isClaudeInstalled ? nil : { viewModel.refresh() }
                )

                PermissionRow(
                    title: "Accessibility",
                    description: "Lets HyperPointer inspect the UI element under your pointer and listen for the global right-click gesture.",
                    statusText: viewModel.isAccessibilityGranted ? "Ready" : "Needs approval",
                    isReady: viewModel.isAccessibilityGranted,
                    primaryTitle: viewModel.isAccessibilityGranted ? "Open Settings" : "Grant Access",
                    secondaryTitle: "Refresh",
                    primaryAction: {
                        if viewModel.isAccessibilityGranted {
                            viewModel.openAccessibilitySettings()
                        } else {
                            viewModel.requestAccessibility()
                        }
                    },
                    secondaryAction: { viewModel.refresh() }
                )

                PermissionRow(
                    title: "Screen Recording",
                    description: "Allows HyperPointer to include the visible window in the context it sends to Claude. macOS may require a relaunch after this changes.",
                    statusText: viewModel.isScreenRecordingGranted ? "Ready" : "Needs approval",
                    isReady: viewModel.isScreenRecordingGranted,
                    primaryTitle: viewModel.isScreenRecordingGranted ? "Open Settings" : "Grant Access",
                    secondaryTitle: "Refresh",
                    primaryAction: {
                        if viewModel.isScreenRecordingGranted {
                            viewModel.openScreenRecordingSettings()
                        } else {
                            viewModel.requestScreenRecording()
                        }
                    },
                    secondaryAction: { viewModel.refresh() }
                )

                PermissionRow(
                    title: "Microphone",
                    description: "Optional. Required only for command-held voice input.",
                    statusText: viewModel.statusLabel(for: viewModel.microphoneStatus),
                    isReady: viewModel.microphoneStatus == .authorized,
                    primaryTitle: viewModel.microphoneStatus == .authorized ? "Open Settings" : "Grant Access",
                    secondaryTitle: "Refresh",
                    primaryAction: {
                        if viewModel.microphoneStatus == .authorized {
                            viewModel.openMicrophoneSettings()
                        } else {
                            viewModel.requestMicrophone()
                        }
                    },
                    secondaryAction: { viewModel.refresh() }
                )

                PermissionRow(
                    title: "Speech Recognition",
                    description: "Optional. Used together with the microphone for voice input.",
                    statusText: viewModel.statusLabel(for: viewModel.speechStatus),
                    isReady: viewModel.speechStatus == .authorized,
                    primaryTitle: viewModel.speechStatus == .authorized ? "Open Settings" : "Grant Access",
                    secondaryTitle: "Refresh",
                    primaryAction: {
                        if viewModel.speechStatus == .authorized {
                            viewModel.openSpeechSettings()
                        } else {
                            viewModel.requestSpeechRecognition()
                        }
                    },
                    secondaryAction: { viewModel.refresh() }
                )
            }
            .padding(28)
        }
    }
}

private struct AutomationStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Automation approvals")
                            .font(.system(size: 28, weight: .semibold))
                        Text("Open the apps you care about, then grant Automation one app at a time. This front-loads the macOS approval prompt instead of showing it during the first real task.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button("Refresh List") {
                        viewModel.refresh()
                    }
                }

                HStack(spacing: 10) {
                    Button("Open Automation Settings") {
                        viewModel.openAutomationSettings()
                    }
                    .buttonStyle(.link)

                    Text("Every installed app is listed here. Running apps get an extra badge.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                TextField("Search apps", text: $viewModel.automationSearchQuery)
                    .textFieldStyle(.roundedBorder)

                if viewModel.isLoadingAutomationApps {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning installed applications…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if viewModel.automationApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No applications were found")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Use Refresh List to rescan the standard Applications folders if the install changed while this window was open.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if viewModel.filteredAutomationApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No apps match that search")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Try a shorter app name or search by bundle identifier.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    VStack(spacing: 12) {
                        ForEach(viewModel.filteredAutomationApps) { app in
                            AutomationAppRow(app: app) {
                                viewModel.requestAutomation(for: app)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

// MARK: - Interactive Tutorial

private enum TutorialPhase: Equatable {
    case holdCommand
    case exploring
    case hovering
    case dwelled
    case released
}

private struct ToyItem: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let examplePrompt: String
}

private class TutorialState: ObservableObject {
    @Published var phase: TutorialPhase = .holdCommand
    @Published var hoveredItem: ToyItem?
    @Published var selectedItem: ToyItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dwellTimer: Timer?

    let items: [ToyItem] = [
        ToyItem(name: "Documents", icon: "folder.fill", examplePrompt: "List recent files"),
        ToyItem(name: "Downloads", icon: "folder.fill", examplePrompt: "Clean up old downloads"),
        ToyItem(name: "Projects", icon: "folder.fill", examplePrompt: "Show git status"),
        ToyItem(name: "notes.txt", icon: "doc.text.fill", examplePrompt: "Summarize this"),
        ToyItem(name: "screenshot.png", icon: "photo.fill", examplePrompt: "What's in this image?"),
        ToyItem(name: "budget.csv", icon: "tablecells", examplePrompt: "Chart Q1 expenses"),
    ]

    func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
    }

    func stop() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        globalMonitor = nil
        dwellTimer?.invalidate()
    }

    private func handleFlags(_ event: NSEvent) {
        let commandDown = event.modifierFlags.contains(.command)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .holdCommand:
                if commandDown { self.phase = .exploring }
            case .exploring, .hovering:
                if !commandDown {
                    self.dwellTimer?.invalidate()
                    self.phase = .holdCommand
                    self.hoveredItem = nil
                }
            case .dwelled:
                if !commandDown {
                    self.selectedItem = self.hoveredItem
                    self.phase = .released
                }
            case .released:
                break
            }
        }
    }

    func itemHovered(_ item: ToyItem) {
        guard phase == .exploring || phase == .hovering else { return }
        hoveredItem = item
        phase = .hovering
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.phase == .hovering else { return }
                self.phase = .dwelled
            }
        }
    }

    func itemUnhovered() {
        guard phase == .hovering else { return }
        dwellTimer?.invalidate()
        hoveredItem = nil
        phase = .exploring
    }

    deinit { stop() }
}

private struct FinishStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @StateObject private var tutorial = TutorialState()

    var body: some View {
        ZStack {
            if tutorial.phase == .holdCommand {
                holdCommandView
                    .transition(.opacity)
            } else {
                desktopView
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.3), value: tutorial.phase)
        .animation(.easeOut(duration: 0.15), value: tutorial.hoveredItem?.id)
        .onAppear { tutorial.start() }
        .onDisappear { tutorial.stop() }
    }

    // MARK: - Hold Command Phase

    private var holdCommandView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("\u{2318}")
                .font(.system(size: 56, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
            Text("Hold command")
                .font(.system(size: 24, weight: .semibold))
            Text("You should see a little icon appear next to your cursor.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    // MARK: - Toy Desktop Phase

    private var desktopView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            // Mock Finder window
            VStack(spacing: 0) {
                // Title bar
                HStack(spacing: 8) {
                    Circle().fill(Color.red.opacity(0.7)).frame(width: 12, height: 12)
                    Circle().fill(Color.yellow.opacity(0.7)).frame(width: 12, height: 12)
                    Circle().fill(Color.green.opacity(0.7)).frame(width: 12, height: 12)
                    Spacer()
                    Text("Home")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Color.clear.frame(width: 44, height: 12)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))

                // File list
                VStack(spacing: 0) {
                    ForEach(tutorial.items) { item in
                        toyItemRow(item)
                        if item.id != tutorial.items.last?.id {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(white: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .padding(.horizontal, 28)

            Spacer(minLength: 12)

            // Instruction text
            VStack(spacing: 4) {
                switch tutorial.phase {
                case .exploring:
                    Text("Move your cursor over an item")
                        .font(.system(size: 14, weight: .medium))
                    Text("The panel follows your pointer and reads what's underneath.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                case .hovering:
                    Text("Pause here\u{2026}")
                        .font(.system(size: 14, weight: .medium))
                    Text("Hold still for a moment to lock onto this item.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                case .dwelled:
                    Text("Now release \u{2318}")
                        .font(.system(size: 14, weight: .medium))
                    Text("The panel will anchor and an input field will appear.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                case .released:
                    if let item = tutorial.selectedItem {
                        Text("Type in the HyperPointer panel: \"\(item.examplePrompt)\"")
                            .font(.system(size: 14, weight: .medium))
                        Text("Then press Return to send it to Claude.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                default:
                    EmptyView()
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
    }

    private func toyItemRow(_ item: ToyItem) -> some View {
        let isHovered = tutorial.hoveredItem?.id == item.id
        let showBadge = isHovered && (tutorial.phase == .hovering || tutorial.phase == .dwelled)

        return HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 16))
                .foregroundStyle(item.icon == "folder.fill" ? .blue : .white.opacity(0.6))
                .frame(width: 22)
            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            if showBadge {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.08) : Color.clear)
        .onHover { hovering in
            if hovering {
                tutorial.itemHovered(item)
            } else {
                tutorial.itemUnhovered()
            }
        }
    }

}

private struct PermissionRow: View {
    let title: String
    let description: String
    let statusText: String
    let isReady: Bool
    let primaryTitle: String
    let secondaryTitle: String?
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                        SetupStatusPill(text: statusText, isReady: isReady)
                    }

                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)
            }

            HStack(spacing: 10) {
                Button(primaryTitle, action: primaryAction)
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct AutomationAppRow: View {
    let app: AutomationApp
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(app.bundleIdentifier)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if app.isRunning {
                SetupStatusPill(text: "Open", isReady: true)
            }
            SetupStatusPill(text: app.isGranted ? "Ready" : "Pending", isReady: app.isGranted)

            Button(app.isGranted ? "Retry" : "Allow", action: action)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SetupStatusPill: View {
    let text: String
    let isReady: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isReady ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
            .foregroundStyle(isReady ? Color.green : Color.orange)
            .clipShape(Capsule())
    }
}

private struct SummaryBadge: View {
    let title: String
    let value: String
    let isReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isReady ? Color.primary : Color.orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
