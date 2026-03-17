import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case chat
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .chat:
            return "Chat"
        case .permissions:
            return "Permissions"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Invoke key, sound, and voice behavior"
        case .chat:
            return "Claude model defaults"
        case .permissions:
            return "macOS access and automation"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            return "gearshape"
        case .chat:
            return "bubble.left.and.bubble.right"
        case .permissions:
            return "hand.raised"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection? = .general
    @StateObject private var onboardingViewModel: OnboardingViewModel
    @StateObject private var settingsStore: AppSettingsStore

    init(onAccessibilityStateChange: @escaping (Bool) -> Void) {
        _onboardingViewModel = StateObject(
            wrappedValue: OnboardingViewModel(
                onFinish: {},
                onAccessibilityStateChange: onAccessibilityStateChange
            )
        )
        _settingsStore = StateObject(wrappedValue: AppSettingsStore())
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selectedSection ?? .general {
                case .general:
                    GeneralSettingsPane(
                        onboardingViewModel: onboardingViewModel,
                        settingsStore: settingsStore
                    )
                case .chat:
                    ChatSettingsPane(settingsStore: settingsStore)
                case .permissions:
                    PermissionsSettingsPane(viewModel: onboardingViewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var onboardingViewModel: OnboardingViewModel
    @ObservedObject var settingsStore: AppSettingsStore

    var body: some View {
        SettingsPageScaffold(
            title: "General",
            subtitle: "Choose how HyperPointer wakes up and how much feedback it gives you while you work."
        ) {
            VStack(spacing: 14) {
                invokeHotkeyCard
                soundEffectsCard
                autoVoiceCard
            }
        }
    }

    private var invokeHotkeyCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Invoke hotkey")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Choose which modifier key you hold to bring up HyperPointer. Fn is the safest default if you want to avoid clashes with app shortcuts.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Invoke hotkey", selection: $onboardingViewModel.invokeHotKey) {
                    ForEach(InvokeHotKey.allCases) { hotKey in
                        Text(hotKey.displayName).tag(hotKey)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }
        }
    }

    private var soundEffectsCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sound effects")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Play the same send and response sounds used during onboarding.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $onboardingViewModel.chimeEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: onboardingViewModel.chimeEnabled) { _, enabled in
                        if enabled {
                            onboardingViewModel.soundPlayer.playPress()
                        }
                    }
            }
        }
    }

    private var autoVoiceCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Auto-voice")
                        .font(.system(size: 15, weight: .semibold))
                    Text("When on, voice starts as soon as you hold your invoke key. When off, hold Shift while you hold the invoke key to use voice mode.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $settingsStore.autoVoiceEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

private struct ChatSettingsPane: View {
    @ObservedObject var settingsStore: AppSettingsStore

    var body: some View {
        SettingsPageScaffold(
            title: "Chat",
            subtitle: "Pick the Claude defaults HyperPointer should use whenever it opens a new conversation."
        ) {
            VStack(spacing: 14) {
                defaultModelCard
                fastModeCard
            }
        }
    }

    private var defaultModelCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default model")
                        .font(.system(size: 15, weight: .semibold))
                    Text("This controls the Claude Code model HyperPointer uses by default, plus whether thinking starts enabled or disabled.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Picker("Default model", selection: $settingsStore.defaultModel) {
                        ForEach(ClaudeModelPreset.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Thinking", selection: $settingsStore.thinkingEnabled) {
                        Text("Thinking off").tag(false)
                        Text("Thinking on").tag(true)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
            }
        }
    }

    private var fastModeCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default to fast mode")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Controls whether Opus 4.6 sessions start with Claude Code fast mode enabled. This is on by default.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $settingsStore.fastModeEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

private struct PermissionsSettingsPane: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        SettingsPageScaffold(
            title: "Permissions",
            subtitle: "These macOS permissions let HyperPointer automate apps, capture context, and support voice input on this Mac."
        ) {
            SettingsCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsPermissionStatusRow(
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

                    divider

                    SettingsPermissionStatusRow(
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

                    divider

                    SettingsPermissionStatusRow(
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

                    divider

                    SettingsPermissionStatusRow(
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

                    divider

                    SettingsPermissionStatusRow(
                        title: "Automation",
                        description: "Allow HyperPointer to control other apps via AppleScript.",
                        icon: "bolt.horizontal.circle",
                        state: .action("Grant") {
                            viewModel.openAutomationSettings()
                        }
                    )
                }
            }
        }
    }

    private var divider: some View {
        Divider()
            .padding(.leading, 64)
    }

    private func permissionState(
        isGranted: Bool,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> SettingsPermissionStatusRow.State {
        if isGranted {
            return .granted("Granted")
        }
        if isBusy || viewModel.isPreparingAppBundle {
            return .inProgress
        }
        return .action("Grant", action)
    }
}

private struct SettingsPageScaffold<Content: View>: View {
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
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Color.white.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.black.opacity(0.035), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 22, y: 8)
    }
}

private struct SettingsPermissionStatusRow: View {
    enum State {
        case granted(String)
        case inProgress
        case action(String, () -> Void)
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
        case .action(let label, let action):
            Button(label, action: action)
                .buttonStyle(SettingsPermissionGrantButtonStyle())
        }
    }
}

private struct SettingsPermissionGrantButtonStyle: ButtonStyle {
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
