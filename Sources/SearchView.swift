import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var textHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Selected/highlighted text
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

                Divider()
                    .padding(.horizontal, 8)
            }

            // Menu items — most specific first
            let reversed = Array(viewModel.hoveredParts.reversed())
            ForEach(Array(reversed.enumerated()), id: \.offset) { index, part in
                MenuItemRow(text: part, isFirst: index == 0)

                if index < reversed.count - 1 {
                    Divider()
                        .padding(.horizontal, 8)
                }
            }

            if !viewModel.hoveredParts.isEmpty {
                Divider()
                    .padding(.horizontal, 8)
            }

            // Command input at the bottom
            HStack(alignment: .top, spacing: 4) {
                Text(">")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.top, 1)

                FocusedTextField(text: $viewModel.query, textHeight: $textHeight, onSubmit: {
                    viewModel.launchSelected()
                })
                .frame(height: textHeight)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(minWidth: 180, maxWidth: 360)
        .fixedSize()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
        .padding(16)
        .onKeyPress(.upArrow) {
            viewModel.moveSelection(up: true)
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveSelection(up: false)
            return .handled
        }
    }
}

struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var textHeight: CGFloat
    var onSubmit: () -> Void
    static let maxHeight: CGFloat = 120

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
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
        Coordinator(text: $text, textHeight: $textHeight, onSubmit: onSubmit)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var textHeight: CGFloat
        let onSubmit: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, textHeight: Binding<CGFloat>, onSubmit: @escaping () -> Void) {
            _text = text
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
            let newHeight = min(max(size.height + 4, 18), FocusedTextField.maxHeight)
            DispatchQueue.main.async {
                self.textHeight = newHeight
            }
        }
    }
}

struct MenuItemRow: View {
    let text: String
    let isFirst: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconForItem(text))
                .font(.system(size: 11))
                .foregroundColor(isFirst ? .primary : .secondary)
                .frame(width: 16, alignment: .center)

            Text(displayText(text))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(isFirst ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func displayText(_ text: String) -> String {
        // Strip "role: " prefix since the icon now represents it
        if let colonRange = text.range(of: ": ") {
            return String(text[colonRange.upperBound...])
        }
        return text
    }

    private func iconForItem(_ text: String) -> String {
        let lower = text.lowercased()

        // Specific element roles (from "role: name" format)
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

        // Browser/web-specific items
        if lower.hasPrefix("url:") { return "link.circle" }
        if lower.hasPrefix("id:") { return "number" }
        if lower.hasPrefix("class:") { return "curlybraces" }
        if lower.hasPrefix("href:") { return "arrow.up.right.square" }
        if lower.hasPrefix("tip:") { return "info.circle" }

        // OS-level items (no colon prefix)
        if lower.contains("dock") { return "dock.rectangle" }
        if lower.contains("menu bar") { return "menubar.rectangle" }
        if lower.contains("desktop") { return "desktopcomputer" }
        if lower.contains("widget") { return "widget.small" }
        if lower.contains("notification") { return "bell" }

        // App name (broadest level) — use generic app icon
        return "app"
    }
}
