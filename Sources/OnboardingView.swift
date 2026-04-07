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
        .background(Color(NSColor.windowBackgroundColor))
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
            title: "Welcome to This",
            subtitle: "\"This\" is a powerful local assistant that reads context from your Mac and helps you act on what is on screen."
        ) {
            YouTubeThumbnailLink(videoID: "e7nriIU9bM8")

            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Link("github.com/jasPreMar/this", destination: URL(string: "https://github.com/jasPreMar/this")!)
                    .font(.system(size: 14, weight: .medium))
                    .onboardingClickableCursor()
            }
            .padding(.top, 4)

            SecurityNoticeCard(
                title: "Security notice",
                message: "The connected AI agent can trigger powerful actions on your Mac, including running commands, reading and writing files, and capturing screenshots depending on the permissions you grant.\n\nOnly enable \"This\" if you understand the risks and trust the prompts and integrations you use."
            )
        }
    }
}

private struct ClaudeSetupStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingPageScaffold(
            title: "Choose your setup",
            subtitle: "\"This\" works best when Claude CLI is available on this Mac. You can use this Mac now or configure it later."
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
            subtitle: "These macOS permissions let \"This\" capture context and access the system services you enable on this Mac."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                PermissionStatusRow(
                    title: "Accessibility",
                    description: "Control UI elements and inspect what is under your pointer.",
                    icon: "hand.raised",
                    state: settingsReviewState(
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
                    state: settingsReviewState(
                        isGranted: viewModel.isScreenRecordingGranted,
                        isBusy: viewModel.isScreenRecordingRequestInFlight
                    ) {
                        if !viewModel.isScreenRecordingGranted {
                            viewModel.requestScreenRecording(resumeDestination: .onboarding)
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
                            viewModel.requestMicrophone(resumeDestination: .onboarding)
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
                            viewModel.requestSpeechRecognition(resumeDestination: .onboarding)
                        }
                    }
                )




                Divider()
                    .padding(.leading, 64)

                PermissionStatusRow(
                    title: "Reminders",
                    description: "Allow \"This\" to read or create reminders when needed.",
                    icon: "checklist",
                    state: permissionState(
                        isGranted: viewModel.isRemindersGranted,
                        isBusy: viewModel.isRemindersRequestInFlight
                    ) {
                        if !viewModel.isRemindersGranted {
                            viewModel.requestReminders(resumeDestination: .onboarding)
                        }
                    }
                )

                Divider()
                    .padding(.leading, 64)

                PermissionStatusRow(
                    title: "Input Monitoring",
                    description: "Allow \"This\" to observe input events outside the app when needed.",
                    icon: "keyboard",
                    state: permissionState(
                        isGranted: viewModel.isInputMonitoringGranted,
                        isBusy: viewModel.isInputMonitoringRequestInFlight
                    ) {
                        if !viewModel.isInputMonitoringGranted {
                            viewModel.requestInputMonitoring(resumeDestination: .onboarding)
                        }
                    }
                )
            }
            .cardStyle()
        }
        .onAppear {
            viewModel.refreshWithSettling()
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
        if isBusy {
            return .inProgress
        }
        return .action("Grant", action)
    }

    private func settingsReviewState(
        isGranted: Bool,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> PermissionStatusRow.State {
        if isGranted {
            return .granted("Granted")
        }
        if isBusy {
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

private struct FinishStep: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingPageScaffold(
            title: "Settings",
            subtitle: "Choose your invoke key and sound preferences."
        ) {
            VStack(spacing: 16) {
                invokeKeyCard
                    .cardStyle()

                chimeToggleCard
                    .cardStyle()
            }
        }
    }

    private var invokeKeyCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Invoke hotkey")
                    .font(.system(size: 15, weight: .semibold))
                Text("Choose which modifier key you hold to bring up \"This\". Fn is the safest default if you want to avoid clashes with app shortcuts.")
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
                Text("Play a chime when you send a message and when a response arrives.")
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
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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

private struct YouTubeThumbnailLink: View {
    let videoID: String
    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false

    var body: some View {
        Button {
            let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
            NSWorkspace.shared.open(url)
        } label: {
            ZStack {
                if let thumbnailImage {
                    Image(nsImage: thumbnailImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 314)
                        .clipped()
                } else {
                    Color.black
                        .frame(height: 314)
                }

                Color.black.opacity(isHovered ? 0.15 : 0)

                Circle()
                    .fill(Color.red)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .offset(x: 2)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    .scaleEffect(isHovered ? 1.08 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.1), radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .onboardingClickableCursor()
        .onHover { isHovered = $0 }
        .task {
            guard let url = URL(string: "https://img.youtube.com/vi/\(videoID)/maxresdefault.jpg"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            thumbnailImage = image
        }
    }
}
