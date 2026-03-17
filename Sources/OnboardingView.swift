import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    private let steps = [
        "Welcome",
        "Claude",
        "Permissions",
        "Tutorial"
    ]

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .frame(width: 618, height: 768)
        .background(
            LinearGradient(
                colors: [
                    Color.white,
                    Color(red: 0.985, green: 0.985, blue: 0.99)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch viewModel.currentStep {
            case 0:
                WelcomeStep(viewModel: viewModel)
            case 1:
                ClaudeSetupStep(viewModel: viewModel)
            case 2:
                PermissionsStep(viewModel: viewModel)
            default:
                FinishStep(viewModel: viewModel)
            }
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Group {
                if viewModel.currentStep > 0 {
                    Button {
                        viewModel.previousStep()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .onboardingClickableCursor()
                } else {
                    Color.clear
                        .frame(width: 32, height: 32)
                }
            }

            Spacer()

            PaginationDots(currentStep: viewModel.currentStep, count: steps.count)

            Spacer()

            Button(viewModel.currentStep == steps.count - 1 ? "Finish" : "Next") {
                if viewModel.currentStep == steps.count - 1 {
                    viewModel.finish()
                } else {
                    viewModel.nextStep()
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .onboardingClickableCursor()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }
}

private struct WelcomeStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingPageScaffold(
            title: "Welcome to HyperPointer",
            subtitle: "HyperPointer is a powerful local assistant that reads context from your Mac and helps you act on what is on screen."
        ) {
            SecurityNoticeCard(
                title: "Security notice",
                message: "The connected AI agent can trigger powerful actions on your Mac, including running commands, reading and writing files, and capturing screenshots depending on the permissions you grant.\n\nOnly enable HyperPointer if you understand the risks and trust the prompts and integrations you use."
            )
        }
    }
}

private struct ClaudeSetupStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingPageScaffold(
            title: "Choose your setup",
            subtitle: "HyperPointer works best when Claude CLI is available on this Mac. You can use this Mac now or configure it later."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SetupChoiceRow(
                    title: "This Mac",
                    subtitle: viewModel.isClaudeInstalled
                        ? "Claude CLI is installed and ready to use on this Mac."
                        : "Use Claude CLI on this Mac. Install it first if you have not already.",
                    isSelected: viewModel.claudeSetupChoice == .thisMac
                ) {
                    viewModel.claudeSetupChoice = .thisMac
                }

                Divider()
                    .padding(.horizontal, 18)

                SetupChoiceRow(
                    title: "Configure later",
                    subtitle: "Skip Claude CLI for now and finish the rest of onboarding first.",
                    isSelected: viewModel.claudeSetupChoice == .later
                ) {
                    viewModel.claudeSetupChoice = .later
                }

                if viewModel.claudeSetupChoice == .thisMac && !viewModel.isClaudeInstalled {
                    Divider()
                        .padding(.horizontal, 18)

                    Button("Advanced...") {
                        viewModel.requestClaudeInstall()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .onboardingClickableCursor()
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                }
            }
            .cardStyle()
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingPageScaffold(
            title: "Grant permissions",
            subtitle: "These macOS permissions let HyperPointer automate apps and capture context on this Mac."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                PermissionStatusRow(
                    title: "Automation (AppleScript)",
                    description: "Approve per-app later when HyperPointer asks to control another app.",
                    icon: "bolt.horizontal.circle",
                    state: .informational("Later")
                )

                Divider()
                    .padding(.leading, 64)

                PermissionStatusRow(
                    title: "Accessibility",
                    description: "Control UI elements and inspect what is under your pointer.",
                    icon: "hand.raised",
                    state: permissionState(
                        isGranted: viewModel.isAccessibilityGranted,
                        isBusy: viewModel.isAccessibilityRequestInFlight
                    ) {
                        if !viewModel.isAccessibilityGranted {
                            viewModel.requestAccessibility()
                        }
                    }
                )

                Divider()
                    .padding(.leading, 64)

                PermissionStatusRow(
                    title: "Screen Recording",
                    description: "Capture the visible window for context and screenshots.",
                    icon: "display",
                    state: permissionState(
                        isGranted: viewModel.isScreenRecordingGranted,
                        isBusy: viewModel.isScreenRecordingRequestInFlight
                    ) {
                        if !viewModel.isScreenRecordingGranted {
                            viewModel.requestScreenRecording()
                        }
                    }
                )

                Divider()
                    .padding(.leading, 64)

                PermissionStatusRow(
                    title: "Microphone",
                    description: "Allow voice input while you hold your invoke key.",
                    icon: "mic",
                    state: permissionState(
                        isGranted: viewModel.isMicrophoneGranted,
                        isBusy: viewModel.isMicrophoneRequestInFlight
                    ) {
                        if !viewModel.isMicrophoneGranted {
                            viewModel.requestMicrophone()
                        }
                    }
                )

                Divider()
                    .padding(.leading, 64)

                PermissionStatusRow(
                    title: "Speech Recognition",
                    description: "Transcribe dictated prompts on this Mac.",
                    icon: "waveform",
                    state: permissionState(
                        isGranted: viewModel.isSpeechRecognitionGranted,
                        isBusy: viewModel.isSpeechRecognitionRequestInFlight
                    ) {
                        if !viewModel.isSpeechRecognitionGranted {
                            viewModel.requestSpeechRecognition()
                        }
                    }
                )
                }
                .cardStyle()
            }
        }
    }

    private func permissionState(
        isGranted: Bool,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> PermissionStatusRow.State {
        if isGranted {
            return .granted("Granted")
        }
        if isBusy || viewModel.isPreparingAppBundle {
            return .inProgress
        }
        return .action("Grant", action)
    }
}

private struct OnboardingPageScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                OnboardingHero()

                VStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 520)

                content
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 18)
        }
    }
}

private struct OnboardingHero: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: 148, height: 148)
                .blur(radius: 24)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.24), radius: 24, y: 10)
        }
        .frame(height: 124)
    }
}

private struct SecurityNoticeCard: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 30, height: 30)
                .background(Color.orange.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .cardStyle()
    }
}

private struct SetupChoiceRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                selectionIndicator
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .onboardingClickableCursor()
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                .frame(width: 18, height: 18)
        }
    }
}

private struct PermissionStatusRow: View {
    enum State {
        case granted(String)
        case inProgress
        case action(String, () -> Void)
        case informational(String)
    }

    let title: String
    let description: String
    let icon: String
    let state: State

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            trailingView
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var trailingView: some View {
        switch state {
        case .granted(let text):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.green)
            }
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .action(let title, let action):
            Button(title, action: action)
                .buttonStyle(PermissionGrantButtonStyle())
                .onboardingClickableCursor()
        case .informational(let text):
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
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
        let invokeKeyDown = InvokeHotKey.stored().isPressed(in: event.modifierFlags)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .holdCommand:
                if invokeKeyDown { self.phase = .exploring }
            case .exploring, .hovering:
                if !invokeKeyDown {
                    self.dwellTimer?.invalidate()
                    self.phase = .holdCommand
                    self.hoveredItem = nil
                }
            case .dwelled:
                if !invokeKeyDown {
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
        OnboardingPageScaffold(
            title: "Try HyperPointer",
            subtitle: "Choose your invoke key, then practice the flow before you start using it in real tasks."
        ) {
            VStack(spacing: 16) {
                invokeKeyCard
                    .cardStyle()

                chimeToggleCard
                    .cardStyle()

                ZStack {
                    if tutorial.phase == .holdCommand {
                        holdCommandView
                            .transition(.opacity)
                    } else {
                        desktopView
                            .transition(.opacity)
                    }
                }
                .frame(height: 360)
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.12, green: 0.12, blue: 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .animation(.easeOut(duration: 0.3), value: tutorial.phase)
        .animation(.easeOut(duration: 0.15), value: tutorial.hoveredItem?.id)
        .onAppear { tutorial.start() }
        .onDisappear { tutorial.stop() }
    }

    private var invokeKeyCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Invoke hotkey")
                    .font(.system(size: 15, weight: .semibold))
                Text("Choose which modifier key you hold to bring up HyperPointer. Fn is the safest default if you want to avoid clashes with app shortcuts.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Invoke hotkey", selection: $viewModel.invokeHotKey) {
                ForEach(InvokeHotKey.allCases) { hotKey in
                    Text(hotKey.displayName).tag(hotKey)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
            .onboardingClickableCursor()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var chimeToggleCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chime sound")
                    .font(.system(size: 15, weight: .semibold))
                Text("Play a chime when you press and release the invoke key.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $viewModel.chimeEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onboardingClickableCursor()
                .onChange(of: viewModel.chimeEnabled) { _, enabled in
                    if enabled { viewModel.soundPlayer.playPress() }
                }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    // MARK: - Hold Command Phase

    private var holdCommandView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(viewModel.invokeHotKey.symbol)
                .font(.system(size: 56, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.2))
            Text(viewModel.invokeHotKey.holdLabel)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
            Text("You should see a little icon appear next to your cursor.")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.55))
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
                    Text(viewModel.invokeHotKey.releaseLabel)
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

private struct PaginationDots: View {
    let currentStep: Int
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 110, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.84 : 1))
            )
    }
}

private struct PermissionGrantButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(configuration.isPressed ? 0.16 : 0.12))
            )
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .background(Color.white.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.black.opacity(0.035), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 28, y: 10)
    }

    func onboardingClickableCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
