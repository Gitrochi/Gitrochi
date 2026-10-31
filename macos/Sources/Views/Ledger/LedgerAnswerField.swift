import SwiftUI

/// Where a person answers in place: Return is a new line, ⌘Return saves. The text stays when saving fails.
/// (Windows: features/answer-ledger-question/ui/LedgerAnswerField.tsx)
struct LedgerAnswerField: View {
    let placeholder: String
    @Binding var text: String
    var saveTitle: String = String(localized: "Save")
    var busy = false
    /// Set from outside (the Inbox's A key) to move the cursor here
    var focusRequest = false
    let save: () -> Void
    var dismiss: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.callout)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 38, maxHeight: 96)
                .fixedSize(horizontal: false, vertical: true)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .disabled(busy)
                .accessibilityLabel(placeholder)
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text("Return adds a line · ⌘Return saves").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                if let dismiss {
                    Button("Dismiss", action: dismiss).disabled(busy)
                        .help("Close the question without an answer")
                }
                Button(saveTitle, action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    // only the field being typed in owns ⌘Return, so several answer fields can sit on one page
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help(saveTitle + " (⌘↩)")
            }
            .controlSize(.small)
        }
        .onChange(of: focusRequest, initial: true) { _, wanted in if wanted { focused = true } }
    }
}
