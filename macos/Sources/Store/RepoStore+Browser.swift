import Foundation

/// Browser tabs share the terminal panel's panes: the layout holds their ids next to the terminals'.
/// (Windows: entities/terminal/model/browser.ts)
extension RepoStore {
    func browser(_ id: UUID?) -> BrowserSession? {
        browsers.first { $0.id == id }
    }

    /// The browser tab a pane shows, when it shows one
    func shownBrowser(in pane: TerminalNode.Pane) -> BrowserSession? {
        browser(pane.shown(active: activeTerminalID))
    }

    /// A new browser tab in the focused pane, or beside the pane when one is given
    @discardableResult
    func newBrowser(_ url: URL? = nil, splitting pane: TerminalNode.Pane? = nil) -> BrowserSession {
        let b = BrowserSession(url: url)
        browsers.append(b)
        if let pane, let layout = terminalLayout {
            terminalLayout = layout.splitting(pane.id, .sideBySide, with: b.id)
        } else {
            terminalLayout = TerminalNode.adding(b.id, to: terminalLayout?.pane(of: activeTerminalID)?.id, in: terminalLayout)
        }
        activeTerminalID = b.id
        showTerminal = true
        return b
    }

    /// A link from a terminal: the latest browser tab goes there, otherwise a new one opens beside the terminal
    func openInBrowserTab(_ url: URL, beside session: UUID? = nil) {
        if let b = browsers.last(where: { terminalLayout?.pane(of: $0.id) != nil }) {
            b.open(url.absoluteString)
            selectBrowser(b)
            showTerminal = true
        } else {
            newBrowser(url, splitting: terminalLayout?.pane(of: session ?? activeTerminalID))
        }
    }

    /// A file ⌘-clicked in a terminal: previewed in the latest browser tab, or a new one beside the terminal
    func previewInBrowserTab(_ file: URL, beside session: UUID? = nil) {
        let b = browsers.last(where: { terminalLayout?.pane(of: $0.id) != nil })
            ?? newBrowser(nil, splitting: terminalLayout?.pane(of: session ?? activeTerminalID))
        b.openFile(file)
        selectBrowser(b)
        showTerminal = true
    }

    func selectBrowser(_ b: BrowserSession) {
        activeTerminalID = b.id
        terminalLayout = terminalLayout?.selecting(b.id)
    }

    func closeBrowser(_ b: BrowserSession) {
        b.close()
        browsers.removeAll { $0.id == b.id }
        removeTab(b.id)
    }

    /// Selects a pane's tab, whichever kind it is
    func selectTab(_ id: UUID) {
        if let s = terminals.first(where: { $0.id == id }) { selectTerminal(s) } else if let b = browser(id) { selectBrowser(b) }
    }

    /// Closes a pane's tab, asking first when a terminal still runs something
    func requestCloseTab(_ id: UUID) {
        if let s = terminals.first(where: { $0.id == id }) { requestCloseTerminal(s) } else if let b = browser(id) { closeBrowser(b) }
    }
}
