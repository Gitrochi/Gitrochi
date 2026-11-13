import AppKit
import SwiftUI

/// The redesign's own icons, drawn on a 16 pt grid with a 1.5 pt stroke. The same drawings are in
/// windows/src/shared/ui/DesignIcon.tsx: change both together.
enum DesignIcon: String {
    case home
    case account
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
    case settings
    case chevronDown
    case chevronUp
    case chevronLeft
    case chevronRight
    case commit
    case branch
    case refresh
    case plus
    case terminal
    case search
    case copy
    case close
    case check
    case panelLeft
    case panelRight
    case push
    case pull
    case external
    case sort
    case comment
    case eye
    case sparkles
    case file
    case lock
    case pencil
    case trash
    case person
    case clock
    case alert
    case inbox
    case upFolder
    case whitespace
    case cloud
    case minus
    case more
    case identity
    case people

    fileprivate var drawing: String {
        switch self {
        case .account: return #"<circle cx="8" cy="8" r="6.5"/><circle cx="8" cy="6.6" r="2.1"/><path d="M4 12.6c.9-1.6 2.3-2.4 4-2.4s3.1.8 4 2.4"/>"#
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
        case .settings: return #"<circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1"/>"#
        case .chevronDown: return #"<path d="M4 6l4 4 4-4"/>"#
        case .chevronUp: return #"<path d="M4 10l4-4 4 4"/>"#
        case .chevronLeft: return #"<path d="M10 3.5 5.5 8l4.5 4.5"/>"#
        case .chevronRight: return #"<path d="M6 3.5 10.5 8 6 12.5"/>"#
        case .commit: return #"<circle cx="8" cy="8" r="2.5"/><path d="M1.5 8h4M10.5 8h4"/>"#
        case .branch: return #"<circle cx="4.5" cy="3.5" r="1.5"/><circle cx="4.5" cy="12.5" r="1.5"/><circle cx="11.5" cy="5" r="1.5"/><path d="M4.5 5v6M11.5 6.5c0 3-7 2-7 4.5"/>"#
        case .refresh: return #"<path d="M13 8a5 5 0 1 1-1.46-3.54"/><path d="M13 2.5V5.5H10"/>"#
        case .plus: return #"<path d="M8 3v10M3 8h10"/>"#
        case .terminal: return #"<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M4.5 6l2 2-2 2M8.5 10.5h3"/>"#
        case .search: return #"<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3 3"/>"#
        case .copy: return #"<rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 5.5v-2a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2"/>"#
        case .close: return #"<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>"#
        case .check: return #"<path d="m3.5 8.5 3 3 6-7"/>"#
        case .panelLeft: return #"<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M6 2.5v11"/>"#
        case .panelRight: return #"<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M10 2.5v11"/>"#
        case .push: return #"<path d="M8 13.5v-10M4 7.5l4-4 4 4"/>"#
        case .pull: return #"<path d="M8 2.5v10M4 8.5l4 4 4-4"/>"#
        case .external: return #"<path d="M9 3h4v4M13 3 7.5 8.5M11 9.5V13H3V5h3.5"/>"#
        case .sort: return #"<path d="M5 3v10M2.5 5.5 5 3l2.5 2.5M11 13V3M8.5 10.5 11 13l2.5-2.5"/>"#
        case .comment: return #"<path d="M2.5 3.5h11v7.5H7l-3 2.5V11H2.5z"/>"#
        case .eye: return #"<path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/>"#
        case .sparkles: return #"<path d="M7 2l1.3 3.7L12 7l-3.7 1.3L7 12l-1.3-3.7L2 7l3.7-1.3z"/><path d="M12.5 10.5l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6z"/>"#
        case .file: return #"<path d="M4 1.8h5.2L12 4.6v9.6H4z"/><path d="M9 1.8v3h3"/>"#
        case .lock: return #"<rect x="3.5" y="7" width="9" height="6.5" rx="1.3"/><path d="M5.5 7V5.2a2.5 2.5 0 0 1 5 0V7"/>"#
        case .pencil: return #"<path d="M10.5 2.5l3 3L6 13H3v-3z"/>"#
        case .trash: return #"<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5"/>"#
        case .person: return #"<circle cx="8" cy="5.5" r="2.6"/><path d="M3 14c.6-2.8 2.6-4.2 5-4.2s4.4 1.4 5 4.2"/>"#
        case .clock: return #"<circle cx="8" cy="8" r="6.2"/><path d="M8 4.8V8l2.2 1.6"/>"#
        case .alert: return #"<circle cx="8" cy="8" r="6.2"/><path d="M8 4.8v3.6M8 11.1v.1"/>"#
        case .inbox: return #"<path d="M2 9.5 3.8 3.5h8.4L14 9.5v3a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z"/><path d="M2 9.5h3.2l.8 1.6h4l.8-1.6H14"/>"#
        case .upFolder: return #"<path d="M13 13H8.5A3.5 3.5 0 0 1 5 9.5V3M2 6l3-3 3 3"/>"#
        case .whitespace: return #"<path d="M7.5 13V3h5M10.5 3v10M7.5 3H6a2.5 2.5 0 0 0 0 5h1.5"/>"#
        case .cloud: return #"<path d="M4.6 12.5h7a2.9 2.9 0 0 0 .4-5.8 4 4 0 0 0-7.7.9 2.5 2.5 0 0 0 .3 4.9z"/>"#
        case .minus: return #"<path d="M3.5 8h9"/>"#
        case .identity: return #"<rect x="1.8" y="3.2" width="12.4" height="9.6" rx="1.6"/><circle cx="5.6" cy="7.2" r="1.4"/><path d="M3.6 10.6c.4-1 1.1-1.5 2-1.5s1.6.5 2 1.5M9.4 6.6h3M9.4 9h2.2"/>"#
        case .people: return #"<circle cx="6" cy="5.5" r="2.2"/><path d="M2 13c.4-2.3 1.9-3.6 4-3.6s3.6 1.3 4 3.6"/><circle cx="11.2" cy="6.2" r="1.7"/><path d="M11.2 9.6c1.6 0 2.6 1 2.9 2.8"/>"#
        case .more: return #"<circle cx="3.5" cy="8" r="1.3" fill="black" stroke="none"/><circle cx="8" cy="8" r="1.3" fill="black" stroke="none"/><circle cx="12.5" cy="8" r="1.3" fill="black" stroke="none"/>"#
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

/// Takes the size of the text around it, as a symbol does, unless given one: an invisible symbol holds the place
struct DesignIconImage: View {
    let icon: DesignIcon
    var size: CGFloat?

    var body: some View {
        let image = Image(nsImage: icon.image).renderingMode(.template).resizable()
        Group {
            if let size { image.frame(width: size, height: size) }
            else { Image(systemName: "square").hidden().overlay(image.scaledToFit()) }
        }
        .accessibilityHidden(true)
    }
}

/// What the app's `Image(systemName:)` became: the same name and size, the redesign's drawing
struct SymbolIcon: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        if let image = DesignSymbols.image(name) {
            Image(systemName: "square").hidden()
                .overlay(Image(nsImage: image).renderingMode(.template).resizable().scaledToFit())
                .accessibilityHidden(true)
        } else {
            Image(systemName: name)
        }
    }
}

extension DesignSymbols {
    @MainActor private static var images: [String: NSImage] = [:]

    @MainActor static func image(_ name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard let drawing = drawings[name] else { return nil }
        func picture(_ body: String, solid: Bool) -> NSImage? {
            let weight = drawing.grid == 16 ? "1.5" : "2.25"
            let paint = solid ? #"fill="black" stroke="black""# : #"fill="none" stroke="black""#
            let head = #"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 \#(drawing.grid) \#(drawing.grid)" \#(paint) stroke-width="\#(weight)" stroke-linecap="round" stroke-linejoin="round">"#
            return NSImage(data: Data((head + body + "</svg>").utf8))
        }
        guard let shape = picture(drawing.shape, solid: drawing.solid) else { return nil }
        var result = shape
        if let cutout = drawing.cutout.flatMap({ picture($0, solid: false) }) {
            result = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                shape.draw(in: rect)
                cutout.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
                return true
            }
        }
        result.isTemplate = true
        images[name] = result
        return result
    }

    /// For the places that only take an Image (menus, tab items): a fixed 14 pt icon
    @MainActor static func labelImage(_ name: String) -> Image {
        guard let image = image(name)?.copy() as? NSImage else { return Image(systemName: name) }
        image.size = NSSize(width: 14, height: 14)
        return Image(nsImage: image).renderingMode(.template)
    }
}

extension Label where Title == Text, Icon == Image {
    @MainActor init(_ title: LocalizedStringKey, symbol: String) {
        self.init { Text(title) } icon: { DesignSymbols.labelImage(symbol) }
    }

    @MainActor @_disfavoredOverload init<S: StringProtocol>(_ title: S, symbol: String) {
        self.init { Text(title) } icon: { DesignSymbols.labelImage(symbol) }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    @MainActor init(_ title: LocalizedStringKey, symbol: String, role: ButtonRole? = nil, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, symbol: symbol) }
    }

    @MainActor @_disfavoredOverload init<S: StringProtocol>(_ title: S, symbol: String, role: ButtonRole? = nil, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, symbol: symbol) }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, SymbolIcon>, Description == Text?, Actions == EmptyView {
    @MainActor init(_ title: LocalizedStringKey, symbol: String, description: Text? = nil) {
        self.init { SwiftUI.Label { Text(title) } icon: { SymbolIcon(symbol) } } description: { description } actions: { EmptyView() }
    }

    @MainActor @_disfavoredOverload init<S: StringProtocol>(_ title: S, symbol: String, description: Text? = nil) {
        self.init { SwiftUI.Label { Text(title) } icon: { SymbolIcon(symbol) } } description: { description } actions: { EmptyView() }
    }
}
