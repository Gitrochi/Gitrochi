import AppKit
import SwiftUI

/// The redesign's own icons, drawn on a 16 pt grid with a 1.5 pt stroke. The same drawings are in
/// windows/src/shared/ui/DesignIcon.tsx: change both together.
enum DesignIcon: String {
    case home
    case repository
    case compare
    case rebase
    case code
    case pullRequests
    case issues
    case actions
    case releases
    case projects
    case flows
    case ledger
    case settings

    fileprivate var drawing: String {
        switch self {
        case .home: return #"<path d="M2.5 7.2 8 2.8l5.5 4.4"/><path d="M4 6.2V13h3v-3.2h2V13h3V6.2"/>"#
        case .repository: return #"<path d="M1.8 4.2a1 1 0 0 1 1-1h3.1l1.4 1.5h5.9a1 1 0 0 1 1 1v6.6a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z"/>"#
        case .compare: return #"<path d="M2.5 5.5h10M10 3l2.5 2.5L10 8"/><path d="M13.5 10.5h-10M6 8l-2.5 2.5L6 13"/>"#
        case .rebase: return #"<circle cx="3.2" cy="4" r="1"/><circle cx="3.2" cy="8" r="1"/><circle cx="3.2" cy="12" r="1"/><path d="M6.5 4h7M6.5 8h7M6.5 12h7"/>"#
        case .code: return #"<path d="M5.5 4.5 2 8l3.5 3.5M10.5 4.5 14 8l-3.5 3.5M9.2 3 6.8 13"/>"#
        case .pullRequests: return #"<circle cx="4.5" cy="3.5" r="1.5"/><circle cx="4.5" cy="12.5" r="1.5"/><circle cx="11.5" cy="12.5" r="1.5"/><path d="M4.5 5v6M11.5 11V6.5a2 2 0 0 0-2-2H7.5M9 3 7.5 4.5 9 6"/>"#
        case .issues: return #"<circle cx="8" cy="8" r="6"/><circle cx="8" cy="8" r="1.4"/>"#
        case .actions: return #"<circle cx="8" cy="8" r="6"/><path d="M6.8 5.6v4.8l3.8-2.4z"/>"#
        case .releases: return #"<path d="M2.5 2.5h5.2l6 6-5.2 5.2-6-6z"/><circle cx="5.4" cy="5.4" r="0.8"/>"#
        case .projects: return #"<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M6 3v10M10 3v10"/>"#
        case .flows: return #"<rect x="2" y="2.5" width="4.5" height="3.5" rx="1"/><rect x="9.5" y="10" width="4.5" height="3.5" rx="1"/><path d="M4.2 6v4.2a1.5 1.5 0 0 0 1.5 1.5h3.8"/>"#
        case .ledger: return #"<path d="M2.5 4.4l1.3 1.3L6.2 3.2M2.5 10.4l1.3 1.3 2.4-2.5M8.5 4.6h5M8.5 10.6h5"/>"#
        case .settings: return #"<circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1"/>"#
        }
    }

    @MainActor private static var images: [DesignIcon: NSImage] = [:]

    /// A template image, so it takes the colour of the text around it
    @MainActor fileprivate var image: NSImage {
        if let image = Self.images[self] { return image }
        let source = #"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="black" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">"#
        let image = NSImage(data: Data((source + drawing + "</svg>").utf8)) ?? NSImage()
        image.isTemplate = true
        Self.images[self] = image
        return image
    }
}

extension WorkspaceDestination {
    /// nil for a page the Shell board draws no icon for: it keeps `symbol`
    var designIcon: DesignIcon? {
        switch self {
        case .account: return nil
        case .home: return .home
        case .repository: return .repository
        case .compare: return .compare
        case .rebase: return .rebase
        case .code: return .code
        case .pullRequests: return .pullRequests
        case .issues: return .issues
        case .actions: return .actions
        case .releases: return .releases
        case .projects: return .projects
        case .flows: return .flows
        case .ledger: return .ledger
        }
    }
}

struct DesignIconImage: View {
    let icon: DesignIcon
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: icon.image).renderingMode(.template).resizable().frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A page's icon in the rail and the sidebar
struct NavigationPageIcon: View {
    let page: WorkspaceDestination
    var size: CGFloat = 16

    var body: some View {
        if let icon = page.designIcon { DesignIconImage(icon: icon, size: size) }
        else { Image(systemName: page.symbol).font(.system(size: size)).frame(width: size, height: size) }
    }
}
