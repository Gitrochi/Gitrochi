import SwiftUI

// One form each for what failed, for what needs the user, and for why a button can't be used (docs/design.md,
// Controls). (Windows: shared/ui/NoticeBlock.tsx)

/// A notice's button: plain, unless it is the region's one main action
struct NoticeAction {
    let title: String
    var filled = false
    /// Why it can't be used now: the button is disabled and says so beside it
    var disabledReason: String? = nil
    let run: () -> Void
}

/// A white strip with a hairline (a tint means selection): a 14 pt icon, a 13 pt semibold line in its tone, a 12 pt
/// caption and the actions. One action sits on the right; two go on a row below the words.
struct NoticeBlock: View {
    let symbol: String
    var tone = StudioStyle.Tone.waiting
    let title: String
    var caption: String? = nil
    /// The server's own words, on hover
    var detail: String? = nil
    var actions: [NoticeAction] = []
    /// Something is under way (an approval, a retry): a spinner beside the actions, which wait for it
    var busy = false
    /// The actions always sit under the words, as in a popover where the notice leads
    var stacked = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolIcon(symbol).font(.system(size: 14)).foregroundStyle(tone.text).frame(height: 17).accessibilityHidden(true)
            if stacked {
                words(below: !actions.isEmpty || busy).frame(maxWidth: .infinity, alignment: .leading)
            } else if actions.count == 1 || (actions.isEmpty && busy) {
                // one action sits on the right while the words keep 160 pt, and drops below them in a narrow column
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        words(below: false).frame(minWidth: 160, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
                        buttons
                    }
                    words(below: true).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                words(below: actions.count > 1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
        .help(detail ?? "")
        .accessibilityElement(children: .contain)
    }

    private func words(below: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tone.text)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let caption {
                Text(verbatim: caption).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if below { buttons.padding(.top, 6) }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            ForEach(actions.indices, id: \.self) { index in
                NoticeButton(action: actions[index]).disabled(busy)
            }
        }
        .fixedSize()
    }
}

private struct NoticeButton: View {
    let action: NoticeAction

    var body: some View {
        Group {
            if action.filled {
                Button(action.title, action: action.run).hostedListFilledButton()
            } else {
                Button(action.title, action: action.run).buttonStyle(HostedListButtonStyle())
            }
        }
        .disabledReason(action.disabledReason)
    }
}

/// What failed, placed next to it: the failed icon, "Couldn't reach github.com", a caption (how old the data on screen
/// is, or what went wrong) and a plain Retry
struct FailureBlock: View {
    let title: String
    var caption: String? = nil
    /// The server's own words, on hover
    var detail: String? = nil
    /// A retry is under way
    var retrying = false
    let retry: () -> Void

    var body: some View {
        NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: title, caption: caption, detail: detail,
                    actions: [NoticeAction(title: String(localized: "Retry"), run: retry)], busy: retrying)
    }
}

/// The sidebar's form of a notice: one row as tall as its neighbours, the title in its tone, one small action on the
/// right and the caption on hover. The page keeps the full block. (Windows: NoticeRow)
struct NoticeRow: View {
    let symbol: String
    var tone = StudioStyle.Tone.waiting
    let title: String
    var caption: String? = nil
    var action: NoticeAction? = nil
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            SymbolIcon(symbol).font(.system(size: 12)).foregroundStyle(tone.text).accessibilityHidden(true)
            Text(verbatim: title).font(.system(size: 13)).foregroundStyle(tone.text).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                ProgressView().controlSize(.mini)
            } else if let action {
                Button(action.title, action: action.run).buttonStyle(.link).font(.system(size: 12)).fixedSize()
                    .disabled(action.disabledReason != nil)
            }
        }
        .help(caption.map { "\(title)\n\($0)" } ?? title)
        .accessibilityElement(children: .contain)
    }
}

/// A failure in the sidebar: the failed icon, "Couldn't reach github.com" and Retry, the server's words on hover
struct FailureRow: View {
    let title: String
    var caption: String? = nil
    var retrying = false
    let retry: () -> Void

    var body: some View {
        NoticeRow(symbol: "xmark.circle.fill", tone: .failed, title: title, caption: caption,
                  action: NoticeAction(title: String(localized: "Retry"), run: retry), busy: retrying)
    }
}

/// A disabled button says why, in 12 pt grey 8 pt before it; without a reason it is the button alone
struct DisabledReason: ViewModifier {
    let reason: String?

    /// The reason a primary action gives while a failure above it blocks it
    static var retryAbove: String { String(localized: "Retry above") }

    func body(content: Content) -> some View {
        if let reason {
            HStack(spacing: 8) {
                Text(verbatim: reason).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .lineLimit(2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                content.disabled(true).accessibilityHint(Text(verbatim: reason))
            }
        } else {
            content
        }
    }
}

extension View {
    /// Disables the button while there is a reason, and shows the reason beside it
    func disabledReason(_ reason: String?) -> some View { modifier(DisabledReason(reason: reason)) }
}
