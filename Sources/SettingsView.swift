import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
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
    private let onCheckForUpdates: () -> Void
    private let onLeaveFeedback: () -> Void

    init(
        initialSection: SettingsSection = .general,
        onAccessibilityStateChange: @escaping (Bool) -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onLeaveFeedback: @escaping () -> Void
    ) {
        _selectedSection = State(initialValue: initialSection)
        _onboardingViewModel = StateObject(
            wrappedValue: OnboardingViewModel(
                onFinish: {},
                onAccessibilityStateChange: onAccessibilityStateChange
            )
        )
        _settingsStore = StateObject(wrappedValue: AppSettingsStore())
        self.onCheckForUpdates = onCheckForUpdates
        self.onLeaveFeedback = onLeaveFeedback
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .listStyle(.sidebar)

                Divider()

                VStack(spacing: 8) {
                    SettingsSidebarActionButton(
                        title: "Check for Updates",
                        symbolName: "arrow.down.circle",
                        action: onCheckForUpdates
                    )

                    SettingsSidebarActionButton(
                        title: "Leave Feedback",
                        symbolName: "bubble.left.and.bubble.right",
                        action: onLeaveFeedback
                    )
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
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

private struct SettingsSidebarActionButton: View {
    let title: String
    let symbolName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))

                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var onboardingViewModel: OnboardingViewModel
    @ObservedObject var settingsStore: AppSettingsStore

    var body: some View {
        SettingsPageScaffold(
            title: "General",
            subtitle: "Choose how \"This\" wakes up and how much feedback it gives you while you work."
        ) {
            VStack(spacing: 14) {
                invokeHotkeyCard
                soundEffectsCard
                ghostCursorCard
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
                    Text("Choose which modifier key you hold to bring up \"This\". Fn is the safest default if you want to avoid clashes with app shortcuts.")
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

    private var ghostCursorCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agent cursor")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Show a synthetic cursor overlay that follows the agent’s attention while a task is running.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $settingsStore.ghostCursorEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Click sound")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Optional soft feedback when the ghost cursor lands on click-like actions.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $settingsStore.ghostCursorClickSoundEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!settingsStore.ghostCursorEnabled)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Debug labels")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Show short labels under the ghost cursor for tuning and troubleshooting.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $settingsStore.ghostCursorDebugLabelsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!settingsStore.ghostCursorEnabled)
                }
            }
        }
    }
}

private struct ChatSettingsPane: View {
    @ObservedObject var settingsStore: AppSettingsStore

    var body: some View {
        SettingsPageScaffold(
            title: "Chat",
            subtitle: "Pick the Claude defaults \"This\" should use whenever it opens a new conversation."
        ) {
            VStack(spacing: 14) {
                defaultModelCard
                fastModeCard
                structuredUICard
            }
        }
    }

    private var defaultModelCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default model")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Controls the Claude Code model \"This\" uses by default, plus whether thinking starts enabled or disabled.")
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

    @State private var showStructuredUIPreview = false

    private var structuredUICard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Structured UI")
                            .font(.system(size: 15, weight: .semibold))
                        Text("When enabled, Claude can render rich UI components (cards, lists, tables) instead of plain markdown.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $settingsStore.structuredUIEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Button("Preview Structured UI") {
                    showStructuredUIPreview = true
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .sheet(isPresented: $showStructuredUIPreview) {
            StructuredUIPreviewSheet()
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
            subtitle: "These macOS permissions let \"This\" capture context, support voice input, and access the system services you enable on this Mac."
        ) {
            SettingsCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsPermissionStatusRow(
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

                    divider

                    SettingsPermissionStatusRow(
                        title: "Screen Recording",
                        description: "Capture the visible window for context and screenshots.",
                        icon: "display",
                        state: settingsReviewState(
                            isGranted: viewModel.isScreenRecordingGranted,
                            isBusy: viewModel.isScreenRecordingRequestInFlight
                        ) {
                            if !viewModel.isScreenRecordingGranted {
                                viewModel.requestScreenRecording(resumeDestination: .settingsPermissions)
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
                                viewModel.requestMicrophone(resumeDestination: .settingsPermissions)
                            }
                        }
                    )

                    divider

                    SettingsPermissionStatusRow(
                        title: "Reminders",
                        description: "Allow \"This\" to read or create reminders when needed.",
                        icon: "checklist",
                        state: permissionState(
                            isGranted: viewModel.isRemindersGranted,
                            isBusy: viewModel.isRemindersRequestInFlight
                        ) {
                            if !viewModel.isRemindersGranted {
                                viewModel.requestReminders(resumeDestination: .settingsPermissions)
                            }
                        }
                    )

                    divider

                    SettingsPermissionStatusRow(
                        title: "Input Monitoring",
                        description: "Allow \"This\" to observe input events outside the app when needed.",
                        icon: "keyboard",
                        state: permissionState(
                            isGranted: viewModel.isInputMonitoringGranted,
                            isBusy: viewModel.isInputMonitoringRequestInFlight
                        ) {
                            if !viewModel.isInputMonitoringGranted {
                                viewModel.requestInputMonitoring(resumeDestination: .settingsPermissions)
                            }
                        }
                    )
                }
            }
        }
        .onAppear {
            viewModel.refreshWithSettling()
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
        if isBusy {
            return .inProgress
        }
        return .action("Grant", action)
    }

    private func settingsReviewState(
        isGranted: Bool,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> SettingsPermissionStatusRow.State {
        if isGranted {
            return .granted("Granted")
        }
        if isBusy {
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
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
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

// MARK: - Structured UI Preview Sheet

private struct StructuredUIPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var sampleResponse: UIResponse {
        let json = """
        {
            "title": "Project Dashboard",
            "spoken_summary": "Here is a preview of structured UI components.",
            "layout": {
                "type": "vstack",
                "spacing": 16,
                "alignment": "leading",
                "children": [
                    {
                        "type": "hstack",
                        "spacing": 12,
                        "children": [
                            {"type": "stat", "label": "Open Issues", "value": "23", "color": "orange", "icon": "exclamationmark.triangle"},
                            {"type": "stat", "label": "Resolved", "value": "142", "color": "green", "icon": "checkmark.circle"},
                            {"type": "stat", "label": "In Progress", "value": "8", "color": "blue", "icon": "arrow.triangle.2.circlepath"}
                        ]
                    },
                    {
                        "type": "card",
                        "child": {
                            "type": "vstack",
                            "alignment": "leading",
                            "spacing": 8,
                            "children": [
                                {"type": "text", "content": "Recent Activity", "style": "headline", "weight": "bold"},
                                {"type": "text", "content": "Last 7 days across all repositories", "style": "subheadline", "color": "secondary"},
                                {"type": "divider"},
                                {"type": "progress", "value": 0.73, "total": 1.0, "label": "Sprint Progress", "color": "blue"}
                            ]
                        }
                    },
                    {
                        "type": "chart",
                        "variant": "bar",
                        "title": "Commits by Day",
                        "data": [
                            {"label": "Mon", "value": 12, "color": "blue"},
                            {"label": "Tue", "value": 19, "color": "blue"},
                            {"label": "Wed", "value": 8, "color": "blue"},
                            {"label": "Thu", "value": 15, "color": "blue"},
                            {"label": "Fri", "value": 22, "color": "blue"}
                        ]
                    },
                    {
                        "type": "table",
                        "title": "Top Contributors",
                        "headers": ["Name", "Commits", "Lines Changed"],
                        "rows": [
                            ["Alice", "34", "+1,240 / -380"],
                            ["Bob", "28", "+890 / -210"],
                            ["Charlie", "19", "+560 / -140"]
                        ]
                    },
                    {
                        "type": "hstack",
                        "spacing": 8,
                        "children": [
                            {"type": "badge", "text": "v2.1.0", "color": "green"},
                            {"type": "badge", "text": "beta", "color": "orange"},
                            {"type": "badge", "text": "macOS", "color": "blue"}
                        ]
                    }
                ]
            }
        }
        """
        return try! JSONDecoder().decode(UIResponse.self, from: json.data(using: .utf8)!)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Structured UI Preview")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !sampleResponse.title.isEmpty {
                        Text(sampleResponse.title)
                            .font(.headline)
                    }
                    NodeRenderer(node: sampleResponse.layout)
                }
                .padding()
            }
        }
        .frame(width: 500, height: 600)
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
