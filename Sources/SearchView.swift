import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var textHeight: CGFloat = 18
    @State private var textWidth: CGFloat = FocusedTextField.minWidth

    var body: some View {
        if viewModel.isMinimalMode {
            minimalIndicator
        } else {
            fullPanel
        }
    }

    private var minimalIndicator: some View {
        Group {
            if let icon = viewModel.hoveredContextIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .padding(16)
    }

    private var fullPanel: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeaderSection(viewModel: viewModel)

                if viewModel.hasPanelHeaderContent && !viewModel.isCommandKeyMode {
                    Divider()
                        .padding(.horizontal, 8)
                }

                if !viewModel.isCommandKeyMode && !viewModel.isVoiceModeActive {
                    PanelInputRow(
                        viewModel: viewModel,
                        textWidth: $textWidth,
                        textHeight: $textHeight
                    )
                }
            }
        }
    }
}

struct PanelSurface<Content: View>: View {
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let fixedHeight: CGFloat?
    private let content: Content

    init(
        minWidth: CGFloat = 188,
        maxWidth: CGFloat = 360,
        fixedHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.fixedHeight = fixedHeight
        self.content = content()
    }

    var body: some View {
        content
            .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
            .frame(height: fixedHeight, alignment: .top)
            .fixedSize(horizontal: true, vertical: fixedHeight == nil)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .padding(16)
    }
}

struct PanelHeaderSection<Accessory: View>: View {
    @ObservedObject var viewModel: SearchViewModel
    private let accessory: Accessory
    private let showsCloseButtonOnHover: Bool
    private let onClose: (() -> Void)?

    init(
        viewModel: SearchViewModel,
        showsCloseButtonOnHover: Bool = false,
        onClose: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.viewModel = viewModel
        self.showsCloseButtonOnHover = showsCloseButtonOnHover
        self.onClose = onClose
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.selectedText.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                        .frame(width: 16, alignment: .center)

                    Text(viewModel.selectedText)
                        .font(.system(size: 12))
                        .italic()
                        .lineLimit(2)
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
            }

            if !viewModel.selectedText.isEmpty, viewModel.hoveredParts.last != nil {
                Divider()
                    .padding(.horizontal, 8)
            }

            if let visiblePart = viewModel.hoveredParts.last {
                HStack(spacing: 8) {
                    ContextSummaryView(
                        text: visiblePart,
                        appIcon: viewModel.hoveredContextIcon,
                        contextText: viewModel.hoveredParts.first,
                        voiceState: viewModel.voiceState,
                        voiceLevel: viewModel.voiceLevel,
                        showsCloseButtonOnHover: showsCloseButtonOnHover,
                        onClose: onClose
                    )
                    accessory
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            } else if viewModel.isVoiceModeActive {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 16, alignment: .center)

                    Group {
                        switch viewModel.voiceState {
                        case .listening:
                            Text("Release Shift to send")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        case .transcribing:
                            Text("Transcribing...")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        case .failed(let msg):
                            Text(msg)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundColor(.secondary)
                        case .idle:
                            EmptyView()
                        }
                    }

                    Spacer(minLength: 8)
                    VoiceTrailingIndicator(state: viewModel.voiceState, level: viewModel.voiceLevel)
                    accessory
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
    }
}

struct PanelInputRow: View {
    @ObservedObject var viewModel: SearchViewModel
    @Binding var textWidth: CGFloat
    @Binding var textHeight: CGFloat
    var expandsTextField = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(">")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 1)

            FocusedTextField(
                text: $viewModel.query,
                textWidth: $textWidth,
                textHeight: $textHeight,
                onSubmit: {
                    viewModel.submitMessage()
                }
            )
            .frame(width: expandsTextField ? nil : textWidth, height: textHeight)
            .frame(maxWidth: expandsTextField ? .infinity : nil, alignment: .leading)

            if let manager = viewModel.claudeManager,
               manager.status == .waiting || manager.status == .streaming {
                Button(action: {
                    manager.stop()
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
                .help("Stop generation")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var textWidth: CGFloat
    @Binding var textHeight: CGFloat
    var onSubmit: () -> Void
    static let minWidth: CGFloat = 80
    static let maxWidth: CGFloat = 292
    static let maxHeight: CGFloat = 120

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight()
        }
        // Auto-focus
        DispatchQueue.main.async {
            if let window = textView.window, window.firstResponder != textView {
                window.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            textWidth: $textWidth,
            textHeight: $textHeight,
            onSubmit: onSubmit
        )
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var textWidth: CGFloat
        @Binding var textHeight: CGFloat
        let onSubmit: () -> Void
        weak var textView: NSTextView?

        init(
            text: Binding<String>,
            textWidth: Binding<CGFloat>,
            textHeight: Binding<CGFloat>,
            onSubmit: @escaping () -> Void
        ) {
            _text = text
            _textWidth = textWidth
            _textHeight = textHeight
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            updateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }

        func updateHeight() {
            guard let textView = textView,
                  let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let size = layoutManager.usedRect(for: container).size
            let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            let longestLineWidth = textView.string
                .components(separatedBy: .newlines)
                .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            let newWidth = min(
                max(longestLineWidth + 8, FocusedTextField.minWidth),
                FocusedTextField.maxWidth
            )
            let newHeight = min(max(size.height + 4, 18), FocusedTextField.maxHeight)
            DispatchQueue.main.async {
                self.textWidth = newWidth
                self.textHeight = newHeight
            }
        }
    }
}

struct ContextSummaryView: View {
    let text: String
    let appIcon: NSImage?
    let contextText: String?
    let voiceState: SearchViewModel.VoiceState
    let voiceLevel: CGFloat
    let showsCloseButtonOnHover: Bool
    let onClose: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            leadingIcon
                .frame(width: 16, height: 16, alignment: .center)

            Text(displayText(text))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.primary)

            Spacer(minLength: 8)
            VoiceTrailingIndicator(state: voiceState, level: voiceLevel)
        }
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if showsCloseButtonOnHover, isHovered, let onClose {
            Button(action: onClose) {
                Circle()
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
        } else if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: iconForItem(contextText ?? text))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func displayText(_ text: String) -> String {
        if let colonRange = text.range(of: ": ") {
            return String(text[colonRange.upperBound...])
        }
        return text
    }

    private func iconForItem(_ text: String) -> String {
        let lower = text.lowercased()

        if lower.hasPrefix("button:") { return "hand.tap" }
        if lower.hasPrefix("link:") { return "link" }
        if lower.hasPrefix("text field:") || lower.hasPrefix("text area:") { return "character.cursor.ibeam" }
        if lower.hasPrefix("text:") || lower.hasPrefix("static text:") { return "text.alignleft" }
        if lower.hasPrefix("image:") { return "photo" }
        if lower.hasPrefix("checkbox:") { return "checkmark.square" }
        if lower.hasPrefix("radio button:") { return "circle.inset.filled" }
        if lower.hasPrefix("slider:") { return "slider.horizontal.3" }
        if lower.hasPrefix("dropdown:") || lower.hasPrefix("combo box:") || lower.hasPrefix("pop up button:") { return "chevron.up.chevron.down" }
        if lower.hasPrefix("tab:") { return "rectangle.topthird.inset.filled" }
        if lower.hasPrefix("menu item:") || lower.hasPrefix("menu:") { return "filemenu.and.selection" }
        if lower.hasPrefix("toolbar:") { return "menubar.rectangle" }
        if lower.hasPrefix("table:") || lower.hasPrefix("row:") || lower.hasPrefix("cell:") { return "tablecells" }
        if lower.hasPrefix("list:") { return "list.bullet" }
        if lower.hasPrefix("scroll bar:") || lower.hasPrefix("scroll area:") { return "scroll" }
        if lower.hasPrefix("heading:") { return "textformat.size" }
        if lower.hasPrefix("progress bar:") { return "chart.bar.fill" }
        if lower.hasPrefix("color picker:") { return "paintpalette" }
        if lower.hasPrefix("stepper:") { return "plusminus" }
        if lower.hasPrefix("disclosure:") { return "chevron.right" }
        if lower.hasPrefix("web content:") { return "globe" }
        if lower.hasPrefix("group:") { return "rectangle.3.group" }
        if lower.hasPrefix("split view:") { return "rectangle.split.2x1" }
        if lower.hasPrefix("sheet:") || lower.hasPrefix("dialog:") { return "rectangle.center.inset.filled" }
        if lower.hasPrefix("window:") { return "macwindow" }
        if lower.hasPrefix("dock item:") { return "dock.rectangle" }

        if lower.hasPrefix("url:") { return "link.circle" }
        if lower.hasPrefix("id:") { return "number" }
        if lower.hasPrefix("class:") { return "curlybraces" }
        if lower.hasPrefix("href:") { return "arrow.up.right.square" }
        if lower.hasPrefix("tip:") { return "info.circle" }

        if lower.contains("dock") { return "dock.rectangle" }
        if lower.contains("menu bar") { return "menubar.rectangle" }
        if lower.contains("desktop") { return "desktopcomputer" }
        if lower.contains("widget") { return "widget.small" }
        if lower.contains("notification") { return "bell" }

        return "app"
    }
}

struct VoiceTrailingIndicator: View {
    let state: SearchViewModel.VoiceState
    let level: CGFloat

    var body: some View {
        Group {
            switch state {
            case .idle:
                HStack(spacing: 3) {
                    Image(systemName: "shift")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "mic")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Color.secondary.opacity(0.45))
            case .listening:
                CompactVoiceWaveformView(level: level)
            case .transcribing:
                Image(systemName: "ellipsis")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            case .failed:
                EmptyView()
            }
        }
    }
}

struct CompactVoiceWaveformView: View {
    let level: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let phase = abs(sin(time * 6 + Double(index) * 0.65))
                    let amplitude = max(0.18, min(1, level * (0.75 + (phase * 0.75))))

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.95))
                        .frame(width: 3, height: 5 + (amplitude * 14))
                }
            }
            .frame(height: 20, alignment: .center)
        }
    }
}

struct VoiceWaveformView: View {
    let level: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<6, id: \.self) { index in
                    let phase = abs(sin(time * 6 + Double(index) * 0.65))
                    let amplitude = max(0.18, min(1, level * (0.75 + (phase * 0.75))))

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.95))
                        .frame(width: 3, height: 5 + (amplitude * 14))
                }
            }
            .frame(height: 20, alignment: .center)
        }
    }
}

private extension SearchViewModel {
    var hasPanelHeaderContent: Bool {
        !selectedText.isEmpty || hoveredParts.last != nil || isVoiceModeActive
    }
}
