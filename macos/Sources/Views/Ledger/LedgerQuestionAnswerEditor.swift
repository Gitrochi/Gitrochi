import SwiftUI
import AppKit

/// Choices fill an editable draft; only the form's Send answer button sends it.
struct LedgerQuestionAnswerEditor: View {
    let question: LedgerAnswerQuestion
    @Binding var text: String
    var busy = false
    var showsQuestion = true
    var focusRequest = false
    var submit: (() -> Void)?
    @ViewState private var selected: Set<String> = []
    @ViewState private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsQuestion {
                if let header = question.header {
                    Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(question.question).font(.callout.weight(.medium)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                Text(question.multiple ? String(localized: "Choose one or more") : String(localized: "Choose one"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    choice(option)
                }
            }
            LedgerSuggestionTextEditor(text: $text, focused: $focused, suggestion: question.suggestion,
                                       label: String(localized: "Answer to \(question.question)"),
                                       busy: busy, focusRequest: focusRequest, submit: submit)
                .frame(height: 68)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25), lineWidth: focused ? 2 : 1))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Your answer…").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            if let suggestion = question.suggestion {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button("Use suggestion") { text = suggestion }
                        .buttonStyle(.borderless).disabled(busy)
                    Text("Tab").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(suggestion).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                .help("Tab fills an empty answer. You can edit it before sending.")
            }
            Text("Your answer can include a different choice or more detail.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: text, initial: true) { _, draft in
            if draft != LedgerPromptAnswers.selectedText(selected, options: question.options) {
                selected = LedgerPromptAnswers.selectedOptions(text: draft, options: question.options, multiple: question.multiple)
            }
        }
    }

    private func choice(_ option: LedgerPromptText.Option) -> some View {
        let picked = selected.contains(option.label)
        return Button {
            var next = question.multiple ? selected : []
            if next.contains(option.label) { next.remove(option.label) } else { next.insert(option.label) }
            selected = next
            text = LedgerPromptAnswers.selectedText(next, options: question.options)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: picked ? (question.multiple ? "checkmark.square.fill" : "largecircle.fill.circle") : (question.multiple ? "square" : "circle"))
                    .foregroundStyle(picked ? Color.primary : .secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label).font(.callout)
                        if option.recommended, !option.label.localizedCaseInsensitiveContains("recommended") {
                            Text("Recommended").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(picked ? StudioStyle.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The reported-question form uses the same choices and draft editor as a waiting hook.
struct LedgerReportedAnswerField: View {
    let question: LedgerQuestion
    @Binding var text: String
    var busy = false
    var focusRequest = false
    let save: () -> Void
    var dismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LedgerQuestionAnswerEditor(question: LedgerPromptAnswers.question(question), text: $text,
                                       busy: busy, showsQuestion: false, focusRequest: focusRequest,
                                       submit: { if !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { save() } })
            HStack(spacing: 8) {
                Text("Return adds a line · ⌘Return saves").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let dismiss { Button("Dismiss", action: dismiss).disabled(busy) }
                Button("Send answer", action: save).prominentButton(true)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Answer every question before sending.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Native editing keeps input-method composition and ordinary Tab navigation intact.
private struct LedgerSuggestionTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let suggestion: String?
    let label: String
    let busy: Bool
    let focusRequest: Bool
    let submit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = SuggestionTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 68))
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 5, height: 6)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? SuggestionTextView else { return }
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
        editor.isEditable = !busy
        editor.setAccessibilityLabel(label)
        editor.suggestion = suggestion
        editor.fill = { context.coordinator.parent.text = $0 }
        editor.submit = submit
        editor.focusChanged = { value in
            DispatchQueue.main.async { context.coordinator.parent.focused = value }
        }
        if focusRequest && !context.coordinator.requestedFocus {
            DispatchQueue.main.async { if !busy { editor.window?.makeFirstResponder(editor) } }
        }
        context.coordinator.requestedFocus = focusRequest
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LedgerSuggestionTextEditor
        var requestedFocus = false
        init(_ parent: LedgerSuggestionTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }

    private final class SuggestionTextView: NSTextView {
        var suggestion: String?
        var fill: ((String) -> Void)?
        var focusChanged: ((Bool) -> Void)?
        var submit: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { focusChanged?(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { focusChanged?(false) }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command, !hasMarkedText(),
               isEditable, let submit {
                submit()
                return
            }
            if event.keyCode == 48, modifiers.isEmpty,
               LedgerPromptAnswers.canFill(text: string, suggestion: suggestion, composing: hasMarkedText()),
               let suggestion, isEditable {
                fill?(suggestion)
                return
            }
            if event.keyCode == 48, !hasMarkedText(), modifiers.isEmpty || modifiers == .shift {
                if modifiers == .shift { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
                return
            }
            super.keyDown(with: event)
        }
    }
}
