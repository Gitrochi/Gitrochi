import AppKit
import Observation
import SwiftUI

@MainActor private var treeLayoutViews: [String: NSView] = [:]

struct TreeLayoutProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        treeLayoutViews[identifier] = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        treeLayoutViews[identifier] = view
    }
}

@MainActor @Observable private final class TreeLayoutState {
    /// The folders the user opened, by the ids SidebarView uses ("l:feature", "r:origin", "r:origin/feature")
    var expanded: Set<String> = ["l:feature", "r:origin", "r:origin/feature"]
    var filter = ""
    /// Adds a branch and a tag whose names do not fit
    var long = false
}

/// The Branches tab as SidebarView lays it out, from the production field, rows, groups and filter and fixture branches
private struct TreeLayoutFixture: View {
    @Bindable var state: TreeLayoutState
    @FocusState private var focused: Bool

    static let longBranch = "feature/a-very-long-branch-name-that-does-not-fit-in-the-sidebar-at-any-width"
    static let longTag = "release-candidate-with-a-very-long-tag-name-2026"

    private var locals: [Branch] {
        ["main", "feature/checkout", "feature/reviews", "feature/search"].map { branch($0) } + (state.long ? [branch(Self.longBranch)] : [])
    }
    private var remotes: [Branch] {
        ["origin/main", "origin/feature/checkout", "origin/feature/reviews", "origin/feature/search"].map { branch($0, remote: true) }
    }
    private var tags: [String] { ["v1.10.0", "v1.9.0"] + (state.long ? [Self.longTag] : []) }

    var body: some View {
        let query = BranchFilter.query(state.filter)
        let filtering = !query.isEmpty
        let local = BranchFolders(locals) { $0.name }.filtered(query)
        let remote = BranchFolders(remotes) { $0.shortName }.filtered(query)
        let shownTags = tags.filter { BranchFilter.matches($0, query) }
        VStack(alignment: .leading, spacing: 0) {
            // the switch and the field with SidebarView's own paddings
            Segmented(label: "Repository tools", items: [.init(value: "list", title: String(localized: "Branches")), .init(value: "agents", title: String(localized: "Agents"))],
                      selection: "list", fill: true) { _ in }
                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                .background(TreeLayoutProbe(identifier: "switch"))
            SidebarFilterField(text: $state.filter, focused: $focused)
                .background(TreeLayoutProbe(identifier: "field"))
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            if filtering, local.count == 0, remote.count == 0, shownTags.isEmpty {
                HostedListEmpty(symbol: "magnifyingglass", title: String(localized: "No matching branches"),
                                caption: String(localized: "No branch or tag name contains “\(state.filter.trimmingCharacters(in: .whitespacesAndNewlines))”."),
                                actionTitle: String(localized: "Clear filter")) { state.filter = "" }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(TreeLayoutProbe(identifier: "empty"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !filtering || local.count > 0 {
                        section("Local branches", count: local.count) {
                            ForEach(local.loose) { row($0, label: $0.name) }
                            ForEach(local.folders) { f in
                                DisclosureGroup(isExpanded: expansion("l:" + f.name, forced: filtering)) {
                                    ForEach(f.branches) { row($0, label: BranchFolders.leaf($0.name)) }
                                } label: {
                                    groupLabel(f.name, icon: .repository, count: f.branches.count, id: "local-" + f.name)
                                }
                                .disclosureGroupStyle(SidebarTreeGroup())
                            }
                        }
                    }
                    if remote.count > 0 {
                        section("Remotes") {
                            DisclosureGroup(isExpanded: expansion("r:origin", forced: filtering)) {
                                ForEach(remote.loose) { row($0, label: $0.shortName) }
                                ForEach(remote.folders) { f in
                                    DisclosureGroup(isExpanded: expansion("r:origin/" + f.name, forced: filtering)) {
                                        ForEach(f.branches) { row($0, label: BranchFolders.leaf($0.shortName)) }
                                    } label: {
                                        groupLabel(f.name, icon: .repository, count: f.branches.count, id: "remote-" + f.name)
                                    }
                                    .disclosureGroupStyle(SidebarTreeGroup())
                                }
                            } label: {
                                groupLabel("origin", icon: .cloud, count: remote.count, id: "origin")
                            }
                            .disclosureGroupStyle(SidebarTreeGroup())
                        }
                    }
                    if !shownTags.isEmpty {
                        section("Tags", count: shownTags.count) {
                            ForEach(shownTags, id: \.self) { name in
                                HStack(spacing: 6) {
                                    Color.clear.frame(width: 10, height: 16)
                                    DesignIconImage(icon: .releases, size: 13).foregroundStyle(StudioStyle.Rail.icon)
                                        .background(TreeLayoutProbe(identifier: "icon:tag:" + name))
                                    Text(name).lineLimit(1).truncationMode(.tail)
                                }
                                .sidebarTreeRow()
                                .background(TreeLayoutProbe(identifier: "row:tag:" + name))
                            }
                        }
                    }
                }
                // the sidebar's own 4 pt at each side (SidebarView.branchList)
                .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .background(StudioStyle.sidebar)
    }

    private func expansion(_ id: String, forced: Bool) -> Binding<Bool> {
        if forced { return .constant(true) }
        return Binding(get: { state.expanded.contains(id) },
                       set: { if $0 { state.expanded.insert(id) } else { state.expanded.remove(id) } })
    }

    /// The section head as SidebarSection draws it: the chevron over the rows' disclosure column, the count at the right edge
    private func section<Content: View>(_ title: String, count: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DesignIconImage(icon: .chevronDown, size: 10)
                    .background(TreeLayoutProbe(identifier: "chevron:" + title))
                Text(LocalizedStringKey(title))
                Spacer(minLength: 4)
                if let count {
                    StatusPill(title: "\(count)", tone: .neutral)
                        .background(TreeLayoutProbe(identifier: "count:" + title))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StudioStyle.Rail.icon)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(TreeLayoutProbe(identifier: "head:" + title))
            VStack(alignment: .leading, spacing: 0, content: content).padding(.horizontal, 6)
        }
        .padding(.top, 6)
    }

    private func groupLabel(_ text: String, icon: DesignIcon, count: Int, id: String) -> some View {
        HStack(spacing: 6) {
            DesignIconImage(icon: icon, size: 13).foregroundStyle(StudioStyle.Rail.icon)
                .background(TreeLayoutProbe(identifier: "icon:" + id))
            Text(text).lineLimit(1)
                .background(TreeLayoutProbe(identifier: "label:" + id))
            Spacer(minLength: 4)
            StatusPill(title: "\(count)", tone: .neutral)
                .background(TreeLayoutProbe(identifier: "count:" + id))
        }
    }

    private func branch(_ name: String, remote: Bool = false) -> Branch {
        let long = name == Self.longBranch
        return Branch(name: name, target: "fixture", upstream: nil, ahead: name == "main" || name == "feature/search" || long ? 1 : 0,
                      behind: name == "feature/search" ? 2 : long ? 12 : 0, upstreamGone: long, isCurrent: name == "main", isRemote: remote)
    }

    private func row(_ branch: Branch, label: String) -> some View {
        // the long branch carries every mark a row can have
        let marked = branch.name == Self.longBranch
        return BranchRow(branch: branch, label: label, hidden: marked, pinned: marked, protected: marked)
            .sidebarTreeRow()
            .background(TreeLayoutProbe(identifier: "row:" + branch.name))
    }
}

@main private struct SidebarTreeLayoutTest {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var checks: [[String: Any]] = []
        for width: CGFloat in [240, 280, 320] {
            for dark in [false, true] {
                treeLayoutViews.removeAll()
                let state = TreeLayoutState()
                let host = NSHostingView(rootView: TreeLayoutFixture(state: state).preferredColorScheme(dark ? .dark : .light))
                let bounds = NSRect(x: 0, y: 0, width: width, height: 560)
                let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: bounds.height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.frame = bounds
                window.orderBack(nil)

                func settle() {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                    host.layoutSubtreeIfNeeded()
                }

                func shown(_ id: String) -> Bool { treeLayoutViews[id]?.window === window }

                func frame(_ id: String) -> NSRect {
                    guard let view = treeLayoutViews[id], view.window === window else { fatalError("Missing measurement: \(id)") }
                    return view.convert(view.bounds, to: host)
                }

                func close(_ value: CGFloat, _ expected: CGFloat, _ message: String) {
                    precondition(abs(value - expected) <= 1, "\(message): \(value), expected \(expected)")
                }

                func shot(_ name: String) throws -> String {
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No tree bitmap") }
                    host.cacheDisplay(in: bounds, to: bitmap)
                    let file = "sidebar-tree-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(file))
                    return file
                }

                settle()
                for column in ["icon:", "label:"] {
                    close(frame(column + "main").minX, frame(column + "local-feature").minX, "Local siblings must align")
                    close(frame(column + "origin/main").minX, frame(column + "remote-feature").minX, "Remote siblings must align")
                    close(frame(column + "origin/main").minX - frame(column + "origin").minX, 18, "Remote child indentation")
                    close(frame(column + "origin/feature/checkout").minX - frame(column + "remote-feature").minX, 18, "Nested folder indentation")
                }
                let rowNames = ["feature/checkout", "feature/reviews", "feature/search", "origin/feature/checkout", "origin/feature/reviews", "origin/feature/search"]
                for name in rowNames {
                    close(frame("row:" + name).height, 26, "Tree row height")
                    precondition(frame("label:" + name).minX < width - 60, "Branch labels must retain readable width")
                }
                close(abs(frame("row:origin/feature/reviews").minY - frame("row:origin/feature/checkout").minY), 26,
                      "Nested rows must have no extra disclosure spacing")
                // the board's columns: heads 26 pt, their chevron over the rows' disclosure column, counts as 18 pt pills
                // that share the right edge, 18 pt from the sidebar's
                for title in ["Local branches", "Remotes", "Tags"] {
                    close(frame("head:" + title).height, 26, "Section head height")
                    close(frame("chevron:" + title).minX, 18, "Section chevron column")
                    close(frame("chevron:" + title).minX, frame("row:main").minX + 8, "Head chevrons must stand over the rows' disclosure column")
                }
                close(frame("icon:main").minX, 34, "Row icon column")
                close(frame("icon:main").width, 13, "Row icon width")
                close(frame("icon:tag:v1.10.0").minX, frame("icon:main").minX, "Tag and branch icons must align")
                for id in ["count:Local branches", "count:Tags", "count:local-feature", "count:origin", "count:remote-feature"] {
                    close(frame(id).height, 18, "Count pill height")
                    close(frame(id).maxX, width - 18, "Count pills must share the right edge")
                }
                precondition(treeLayoutViews["count:Remotes"] == nil, "The Remotes head carries no count; each remote's row does")
                // the board's field: 28 pt, 10 pt from each side, 10 pt under the switch and 10 pt over the first head
                let field = frame("field"), control = frame("switch"), firstHead = frame("head:Local branches")
                close(field.height, 28, "Filter field height")
                close(field.minX, 10, "Filter field left margin")
                close(field.maxX, width - 10, "Filter field right margin")
                // the switch's probe includes its 12 pt above and 4 pt below
                close(abs(field.midY - control.midY) - field.height / 2 - control.height / 2 + 4, 10, "The field must stand 10 pt under the switch")
                close(abs(firstHead.midY - field.midY) - field.height / 2 - firstHead.height / 2, 10, "The first head must stand 10 pt under the field")
                let screenshot = try shot("default")

                state.expanded.remove("r:origin/feature")
                settle()
                precondition(!shown("row:origin/feature/checkout"), "Collapsed folders must remove their children")
                state.expanded.insert("r:origin/feature")
                settle()
                close(frame("icon:origin/feature/checkout").minX - frame("icon:remote-feature").minX, 18,
                      "Reopening folders must retain indentation")
                state.expanded.remove("r:origin")
                settle()
                precondition(!shown("row:origin/main"), "Collapsed remotes must remove their children")

                // the filter: a match opens the folded remote and its folder; rows and sections without one go
                state.filter = "  SEARCH "
                settle()
                precondition(shown("row:feature/search") && shown("row:origin/feature/search"), "Matches in folders must show, the folded remote opened")
                precondition(!shown("row:main") && !shown("row:feature/checkout") && !shown("row:origin/main") && !shown("head:Tags"),
                             "Rows and sections without a match must go")
                close(frame("row:feature/search").height, 26, "Filtered row height")
                close(frame("count:Local branches").maxX, width - 18, "The filtered count keeps the right edge")
                _ = try shot("filtered")
                state.filter = "v1.9"
                settle()
                precondition(shown("row:tag:v1.9.0") && !shown("row:tag:v1.10.0") && !shown("head:Local branches") && !shown("head:Remotes"), "A tag match must leave the Tags section alone")
                // nothing matches: the empty form inside the sidebar, the field still there
                state.filter = "zzz"
                settle()
                precondition(shown("empty") && shown("field") && !shown("head:Local branches") && !shown("head:Tags"), "No match must show the empty form in place of the sections")
                let empty = frame("empty")
                precondition(empty.minX >= 0 && empty.maxX <= width + 0.5 && empty.height < 240, "The empty form must fit the sidebar")
                _ = try shot("no-match")
                // clearing brings everything back with the remembered folds
                state.filter = ""
                settle()
                precondition(shown("row:main") && shown("head:Tags") && !shown("row:origin/main") && shown("row:feature/checkout"),
                             "Clearing the filter must restore the sections and the remembered folds")
                // a name that does not fit is cut at the end and keeps its marks and counts inside the sidebar
                state.long = true
                state.expanded.insert("r:origin")
                settle()
                let long = frame("row:" + TreeLayoutFixture.longBranch), label = frame("label:" + TreeLayoutFixture.longBranch)
                _ = try shot("long")
                close(long.height, 26, "Long row height")
                // with every mark and both counts the name is down to its ellipsis at 240 pt; nothing leaves the row
                precondition(long.maxX <= width && label.width >= 8 && label.maxX < width - 60, "A long name must be cut, not push the marks out: row \(long), label \(label)")
                precondition(frame("row:tag:" + TreeLayoutFixture.longTag).maxX <= width, "A long tag must stay inside the sidebar")
                checks.append(["width": width, "theme": dark ? "dark" : "light", "childIndent": 18,
                               "rowHeight": 26, "siblingsAligned": true, "headHeight": 26, "countPills": true, "collapseReopen": true,
                               "field": "28 pt, 10 pt above and below", "filter": true, "emptyForm": true, "longName": true, "screenshot": screenshot])
                window.orderOut(nil)
            }
        }
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("PASS: the Filter branches field, production branch rows and tree groups align at 240/280/320 points in light/dark, with 18-point nesting, compact 26-point rows, 26-point heads and count pills at the right edge; the filter opens folded folders, hides what does not match, shows the empty form and restores the folds. \(output.path)")
    }
}
