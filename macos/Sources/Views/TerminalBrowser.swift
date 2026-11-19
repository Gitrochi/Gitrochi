import AppKit
import SwiftUI
import WebKit

/// A browser tab's bar: back, forward, reload, the address and the system browser. (Windows: BrowserToolbar.tsx)
struct BrowserToolbar: View {
    let session: BrowserSession
    @ViewState private var address = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 2) {
            TerminalToolbarButton(symbol: "chevron.left", label: "Back") { session.back() }
                .disabled(!session.canGoBack)
            TerminalToolbarButton(symbol: "chevron.right", label: "Forward") { session.forward() }
                .disabled(!session.canGoForward)
            TerminalToolbarButton(symbol: session.loading ? "xmark" : "arrow.clockwise", label: session.loading ? "Stop" : "Reload") { session.reload() }
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($editing)
                .onSubmit { session.open(address); editing = false }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 4)
                .accessibilityIdentifier("browser-address")
            TerminalToolbarButton(symbol: "arrow.up.forward.app", label: "Open in browser") { session.openExternally() }
                .disabled(session.address.isEmpty)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .onAppear {
            address = session.address
            if session.address.isEmpty { editing = true }
        }
        .onChange(of: session.address) { _, value in
            if !editing { address = value }
        }
        .onChange(of: editing) { _, now in
            if !now { address = session.address.isEmpty ? address : session.address }
        }
    }
}

/// Puts the session's web view in the pane. The view stays with the session, so the page survives tab switches.
struct BrowserHost: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    /// Not re-attached here: when a split collapses, SwiftUI still updates the old container after the new one took
    /// the view (as TerminalHost notes)
    func updateNSView(_ container: NSView, context: Context) {}

    private func attach(to container: NSView) {
        let v = session.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
