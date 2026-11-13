import AppKit
import SwiftUI

// One layout for every sheet (docs/design.md, App shell), and the way a window shows it: attached under the toolbar,
// horizontally centred, with the window behind it not dimmed. (Windows: shared/ui/SharedSheet.tsx)

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

// MARK: - Presentation

/// Closes the sheet it is read in, however the sheet was shown. `dismiss` would close the window under an attached one.
struct SheetCloseAction {
    var close: () -> Void = {}
    func callAsFunction() { close() }
}

private struct SheetCloseKey: EnvironmentKey {
    static let defaultValue = SheetCloseAction()
}

extension EnvironmentValues {
    var closeSheet: SheetCloseAction {
        get { self[SheetCloseKey.self] }
        set { self[SheetCloseKey.self] = newValue }
    }
}

/// A window's attached sheet: one at a time, drawn by `sharedSheetHost()`
@MainActor @Observable final class SharedSheetPresenter {
    struct Presented: Identifiable {
        let id = UUID()
        let owner: UUID
        let content: () -> AnyView
        let close: () -> Void
        let onDismiss: (() -> Void)?
    }

    private(set) var presented: Presented?
    /// The host's window, for a view to tell whether it is in it
    private(set) var windowID: ObjectIdentifier?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private weak var focus: NSResponder?
    private static let open = NSHashTable<NSWindow>.weakObjects()

    /// What `window.attachedSheet != nil` answers for a native sheet, for code that leaves the keys to an open sheet
    static func isPresenting(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return open.contains(window)
    }

    func attach(to window: NSWindow?) {
        if presented != nil { mark(self.window, false); mark(window, true) }
        self.window = window
        windowID = window.map(ObjectIdentifier.init)
    }

    func present(owner: UUID, content: @escaping () -> AnyView, close: @escaping () -> Void, onDismiss: (() -> Void)?) {
        if let previous = presented {
            // a second sheet takes the place of the first, as one binding moving from item to item does
            if previous.owner != owner { previous.close() }
            previous.onDismiss?()
        } else {
            // keys stop going to what is behind the sheet, and go back there when it closes
            // a field being edited answers through the window's shared editor; the field itself is what to go back to
            let responder = window?.firstResponder
            focus = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSResponder : nil } ?? responder
            window?.makeFirstResponder(nil)
            mark(window, true)
        }
        presented = Presented(owner: owner, content: content, close: close, onDismiss: onDismiss)
    }

    func dismiss(owner: UUID) {
        guard let previous = presented, previous.owner == owner else { return }
        presented = nil
        mark(window, false)
        if let window, let focus, focus !== window, (focus as? NSView)?.window === window {
            window.makeFirstResponder(focus)
        }
        focus = nil
        previous.onDismiss?()
    }

    private func mark(_ window: NSWindow?, _ open: Bool) {
        guard let window else { return }
        if open { Self.open.add(window) } else { Self.open.remove(window) }
    }
}

private struct SheetWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    final class Reader: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // after the view update that moved it, so the answer may change what is drawn
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.found?(self.window)
            }
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.found = found
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.found = found }
}

/// The system's sheets put the caret in their first field; an attached one does the same once it is drawn
private struct SheetFirstField: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focus() }
        }

        private func focus() {
            // only while nothing has taken the keys since the sheet opened
            guard let window, let root = window.contentView, window.firstResponder === window else { return }
            let area = convert(bounds, to: nil)
            func fields(_ view: NSView) -> [NSView] {
                let editable = (view as? NSTextField).map { $0.isEditable && $0.isEnabled } ?? (view as? NSTextView)?.isEditable ?? false
                return (editable && !view.isHiddenOrHasHiddenAncestor ? [view] : []) + view.subviews.flatMap(fields)
            }
            func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }
            // window coordinates grow upwards: the highest field is the first one
            let first = fields(root).filter { area.contains(CGPoint(x: frame($0).midX, y: frame($0).midY)) }
                .max { frame($0).midY < frame($1).midY }
            if let first { window.makeFirstResponder(first) }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}
}

/// As tall as the sheet asks to be, like the system's sheets, but never taller than the room under the toolbar
private struct SheetFit: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sheet = subviews.first else { return .zero }
        let ideal = sheet.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return sheet.sizeThatFits(ProposedViewSize(width: proposal.width, height: min(ideal.height, proposal.height ?? ideal.height)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct SharedSheetHost: ViewModifier {
    @ViewState private var presenter = SharedSheetPresenter()

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .background(SheetWindowReader { presenter.attach(to: $0) })
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if let sheet = presenter.presented {
                        // nothing behind the sheet takes a click; the window is not dimmed
                        Color.clear.contentShape(Rectangle()).onTapGesture {}.accessibilityHidden(true)
                        SheetFit {
                            sheet.content().environment(\.closeSheet, SheetCloseAction(close: sheet.close))
                        }
                            .background(StudioStyle.surface)
                            .background(SheetFirstField())
                            // hangs from the toolbar: square on top, 12 pt corners below
                            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                            .overlay {
                                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                                    .strokeBorder(Color.primary.opacity(0.12))
                            }
                            .accessibilityAddTraits(.isModal)
                            .accessibilityIdentifier("shared-sheet")
                            .shadow(color: .black.opacity(0.18), radius: 15, y: 10)
                            .padding(.horizontal, 16).padding(.bottom, 24)
                            .id(sheet.id)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.14), value: presenter.presented?.id)
            }
    }
}

private struct AttachedSheet<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    @ViewBuilder let sheet: (Item) -> Sheet
    @Environment(SharedSheetPresenter.self) private var presenter: SharedSheetPresenter?
    @ViewState private var owner = UUID()
    /// The window this view is in, once it is in one
    @ViewState private var windowID: ObjectIdentifier?

    /// In the host's own window. Settings has no host, and a system sheet is a window of its own even though it
    /// inherits the environment: there the sheet is the system's, with the same layout.
    private var attaches: Bool { windowID != nil && presenter?.windowID == windowID }

    private struct Shown: Equatable {
        let id: Item.ID?
        let attaches: Bool
    }

    func body(content: Content) -> some View {
        content
            .background(SheetWindowReader { windowID = $0.map(ObjectIdentifier.init) })
            .onChange(of: Shown(id: item?.id, attaches: attaches), initial: true) { _, _ in
                if attaches, let item {
                    presenter?.present(owner: owner, content: { AnyView(sheet(item)) }, close: { self.item = nil },
                                       onDismiss: onDismiss)
                } else {
                    presenter?.dismiss(owner: owner)
                }
            }
            .onDisappear { presenter?.dismiss(owner: owner) }
            .sheet(item: Binding(get: { windowID != nil && !attaches ? item : nil }, set: { if $0 == nil, !attaches { item = nil } }),
                   onDismiss: onDismiss) { value in
                sheet(value).environment(\.closeSheet, SheetCloseAction { item = nil })
            }
    }
}

private struct SheetFlag: Identifiable {
    let id = true
}

extension View {
    /// The window's content: sheets shown with `attachedSheet` below it hang from its top edge, under the toolbar
    func sharedSheetHost() -> some View { modifier(SharedSheetHost()) }

    /// Shows a `SharedSheet` attached under the toolbar. The sheet closes itself with `closeSheet`, not `dismiss`.
    func attachedSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                        @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        modifier(AttachedSheet(item: item, onDismiss: onDismiss, sheet: content))
    }

    func attachedSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                    @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(AttachedSheet(item: Binding<SheetFlag?>(get: { isPresented.wrappedValue ? SheetFlag() : nil },
                                                         set: { if $0 == nil { isPresented.wrappedValue = false } }),
                               onDismiss: onDismiss, sheet: { _ in content() }))
    }
}
