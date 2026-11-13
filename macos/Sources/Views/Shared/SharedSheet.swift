import SwiftUI

// One layout for every sheet (docs/design.md, App shell). On macOS it is shown as the system's sheet (`.sheet`), which
// keeps the keys, the toolbar and focus out of the window behind it; Windows hangs it under the toolbar.
// (Windows: shared/ui/SharedSheet.tsx)

/// The sheet's one filled button
struct SheetPrimary {
    let title: String
    /// Why it can't be used now: the button is disabled and says so between Cancel and itself
    var disabledReason: String? = nil
    /// Disabled with nothing to say, while the sheet works
    var disabled = false
    var busy = false
    /// Return presses it
    var isDefault = true
    var identifier: String? = nil
    let run: () -> Void
}

/// Header: a 15 pt semibold title and one 12 pt context line in 20 pt of padding over a 1 pt line. Footer: secondary
/// actions on the left; on the right Cancel, the reason while the primary is disabled, then the one filled primary.
struct SharedSheet<Secondary: View, Content: View>: View {
    let title: String
    /// What the sheet acts on, in one line
    var context: String? = nil
    var width: CGFloat = 560
    /// "Cancel", or "Close" on a sheet with nothing to confirm
    var cancelTitle = String(localized: "Cancel")
    var cancelDisabled = false
    var primary: SheetPrimary? = nil
    let cancel: () -> Void
    /// Plain actions at the footer's left
    @ViewBuilder let secondary: Secondary
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(.system(size: 15, weight: .semibold)).frame(minHeight: 20)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("shared-sheet-title")
                if let context, !context.isEmpty {
                    Text(verbatim: context).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .lineLimit(1).truncationMode(.tail).frame(minHeight: 16).help(context)
                        .accessibilityIdentifier("shared-sheet-context")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            line
            content.frame(maxWidth: .infinity, alignment: .leading)
            line
            HStack(spacing: 8) {
                secondary
                Spacer(minLength: 8)
                if primary?.busy == true { ProgressView().controlSize(.small) }
                Button(cancelTitle, action: cancel).keyboardShortcut(.cancelAction).disabled(cancelDisabled)
                    .accessibilityIdentifier("shared-sheet-cancel")
                if let primary { primaryButton(primary) }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
        .frame(width: width)
    }

    private var line: some View { StudioStyle.border.frame(height: 1) }

    @ViewBuilder private func primaryButton(_ primary: SheetPrimary) -> some View {
        let button = Button(primary.title, action: primary.run).buttonStyle(.borderedProminent)
            .disabled(primary.disabled || primary.busy)
            .accessibilityIdentifier(primary.identifier ?? "shared-sheet-primary")
        if primary.isDefault {
            button.keyboardShortcut(.defaultAction).disabledReason(primary.disabledReason)
        } else {
            button.disabledReason(primary.disabledReason)
        }
    }
}

extension SharedSheet where Secondary == EmptyView {
    init(title: String, context: String? = nil, width: CGFloat = 560, cancelTitle: String = String(localized: "Cancel"),
         cancelDisabled: Bool = false, primary: SheetPrimary? = nil, cancel: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, context: context, width: width, cancelTitle: cancelTitle, cancelDisabled: cancelDisabled,
                  primary: primary, cancel: cancel, secondary: { EmptyView() }, content: content)
    }
}
