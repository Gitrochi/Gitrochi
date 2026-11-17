import AppKit
import Observation
import SwiftUI

/// Every probe view per id: a pinned row moves between the top of the section and its folder, and the view it left can
/// still be updated after the new one is made, so the one to measure is the one in the window
@MainActor private var treeLayoutViews: [String: [NSView]] = [:]

struct TreeLayoutProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        register(view)
    }

    private func register(_ view: NSView) {
        treeLayoutViews[identifier, default: []].removeAll { $0 === view }
        treeLayoutViews[identifier, default: []].append(view)
    }
}

@MainActor @Observable private final class TreeLayoutState {
    /// The folders the user opened, by the ids SidebarView uses ("l:feature", "r:origin", "r:origin/feature")
    var expanded: Set<String> = ["l:feature", "r:origin", "r:origin/feature"]
    var filter = ""
    /// Adds a branch and a tag whose names do not fit
    var long = false
    /// The pinned local branches ("Pin to top") and the checked-out one
    var pinned: Set<String> = []
    var current = "main"
    /// The pinned remote branches and tags, and the tags hidden from the graph, by name
    var pinnedRemotes: Set<String> = []
    var pinnedTags: Set<String> = []
    var hiddenTags: Set<String> = []
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
    private var tags: [Tag] { (["v2.0.0", "v1.10.0", "v1.9.0"] + (state.long ? [Self.longTag] : [])).map { Tag(name: $0, target: "fixture") } }

    var body: some View {
        let query = BranchFilter.query(state.filter)
        let filtering = !query.isEmpty
        let local = BranchFolders(locals, key: { $0.name }, pinned: { state.pinned.contains($0.name) }).filtered(query)
        let remote = BranchFolders(remotes, key: { $0.shortName }, pinned: { state.pinnedRemotes.contains($0.name) }).filtered(query)
        let shownTags = BranchFolders.pinnedFirst(tags.filter { BranchFilter.matches($0.name, query) }, name: \.name) { state.pinnedTags.contains($0.name) }
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
                            ForEach(local.pinned) { row($0, label: $0.name) }
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
                                ForEach(remote.pinned) { row($0, label: $0.shortName) }
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
                            ForEach(shownTags) { t in
                                TagRow(tag: t, pinned: state.pinnedTags.contains(t.name), hidden: state.hiddenTags.contains(t.name))
                                    .sidebarTreeRow()
                                    .background(TreeLayoutProbe(identifier: "row:tag:" + t.name))
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
                      behind: name == "feature/search" ? 2 : long ? 12 : 0, upstreamGone: long, isCurrent: !remote && name == state.current, isRemote: remote)
    }

    private func row(_ branch: Branch, label: String) -> some View {
        // the long branch carries every mark a row can have
        let marked = branch.name == Self.longBranch
        let pinned = (branch.isRemote ? state.pinnedRemotes : state.pinned).contains(branch.name)
        return BranchRow(branch: branch, label: label, hidden: marked, pinned: marked || pinned, protected: marked)
            .sidebarTreeRow()
            .background(TreeLayoutProbe(identifier: "row:" + branch.name))
    }
}

/// The pure grouping behind the pinned rows, as tests/branch-filter.test.ts checks it on Windows: pinned branches lead in
/// name order and leave their folders (an emptied one goes, one with a branch left keeps its form), the filter keeps a
/// pinned match first, and unpinning puts the branch back in its folder; the same for a remote's branches, pinned tags
/// lead Tags, and pins are full refs that keep the local names stored before
private func checkPinnedGrouping() {
    let names = ["develop", "feature/checkout", "feature/reviews", "feature/search", "fix/flaky", "fix/focus", "main", "release/1.10"]
    let branches = names.map { Branch(name: $0, target: $0, upstream: nil, ahead: 0, behind: 0, upstreamGone: false, isCurrent: $0 == "feature/checkout", isRemote: false) }
    func group(_ pins: Set<String>) -> BranchFolders { BranchFolders(branches, key: { $0.name }, pinned: { pins.contains($0.name) }) }
    func expect(_ groups: BranchFolders, _ expected: String, _ message: String) {
        let shape = (["pinned: " + groups.pinned.map(\.name).joined(separator: " "), "loose: " + groups.loose.map(\.name).joined(separator: " ")]
            + groups.folders.map { "\($0.name): " + $0.branches.map { BranchFolders.leaf($0.name) }.joined(separator: " ") }).joined(separator: " | ")
        precondition(shape == expected, "\(message): \(shape)")
    }
    let pins: Set<String> = ["main", "feature/search", "feature/checkout", "fix/flaky", "fix/focus"]
    expect(group([]), "pinned:  | loose: develop main release/1.10 | feature: checkout reviews search | fix: flaky focus", "Nothing pinned must leave the tree as it was")
    let pinned = group(pins)
    expect(pinned, "pinned: feature/checkout feature/search fix/flaky fix/focus main | loose: develop release/1.10 | feature: reviews",
           "Pinned branches must lead in name order, out of their folders, and an emptied folder must go")
    precondition(pinned.count == names.count, "The section's count must hold every local branch")
    expect(pinned.filtered("search"), "pinned: feature/search | loose: ", "The filter must narrow pinned branches by name")
    expect(pinned.filtered("e"), "pinned: feature/checkout feature/search | loose: develop release/1.10 | feature: reviews", "The filter must keep pinned matches first")
    expect(group(pins.subtracting(["feature/search"])), "pinned: feature/checkout fix/flaky fix/focus main | loose: develop release/1.10 | feature: reviews search",
           "Unpinning must put the branch back in its folder")

    // a remote's branches by their names there: a pinned one leads its remote, out of its folder
    let remote = ["origin/main", "origin/feature/checkout", "origin/feature/reviews", "origin/feature/search", "origin/fix/flaky", "origin/fix/focus"]
        .map { Branch(name: $0, target: $0, upstream: nil, ahead: 0, behind: 0, upstreamGone: false, isCurrent: false, isRemote: true) }
    func remoteShape(_ groups: BranchFolders) -> String {
        (["pinned: " + groups.pinned.map(\.shortName).joined(separator: " "), "loose: " + groups.loose.map(\.shortName).joined(separator: " ")]
            + groups.folders.map { "\($0.name): " + $0.branches.map { BranchFolders.leaf($0.shortName) }.joined(separator: " ") }).joined(separator: " | ")
    }
    let remotePins: Set<String> = ["origin/feature/search", "origin/fix/flaky", "origin/fix/focus"]
    let remoteGroups = BranchFolders(remote, key: { $0.shortName }, pinned: { remotePins.contains($0.name) })
    let remoteGrouped = remoteShape(remoteGroups)
    precondition(remoteGrouped == "pinned: feature/search fix/flaky fix/focus | loose: main | feature: checkout reviews",
                 "Pinned remote branches must lead their remote by their names there, out of their folders: \(remoteGrouped)")
    precondition(remoteGroups.count == remote.count, "The remote's count must hold every branch")
    let searchPinned = BranchFolders(remote, key: { $0.shortName }, pinned: { $0.name == "origin/feature/search" })
    precondition(remoteShape(searchPinned.filtered("origin/feature/s")) == "pinned: feature/search | loose: ", "The filter must narrow pinned remote branches by their whole names")
    precondition(remoteShape(searchPinned.filtered("e")) == "pinned: feature/search | loose:  | feature: checkout reviews", "The filter must keep a pinned remote match first")

    // tags have no folders: the pinned ones lead in name order, the rest keep their order
    let tagNames = ["v2.0.0", "v1.10.0", "v1.9.0", "nightly"]
    let tagPins: Set<String> = ["v1.9.0", "nightly", "v1.10.0"]
    precondition(BranchFolders.pinnedFirst(tagNames, name: { $0 }) { tagPins.contains($0) } == ["nightly", "v1.9.0", "v1.10.0", "v2.0.0"], "Pinned tags must lead in name order")
    precondition(BranchFolders.pinnedFirst(tagNames, name: { $0 }) { _ in false } == tagNames, "Nothing pinned must leave the tags as they were")
    precondition(BranchFolders.pinnedFirst(tagNames.filter { BranchFilter.matches($0, "v") }, name: { $0 }) { tagPins.contains($0) } == ["v1.9.0", "v1.10.0", "v2.0.0"],
                 "The filter must keep pinned tag matches first")

    // pins as full refs: the local names stored before keep pinning local branches, and nothing of one name shares a pin
    precondition(PinnedRefs.load(branches: ["main", "feature/search"], refs: []) == ["refs/heads/main", "refs/heads/feature/search"], "Stored local pins must carry over")
    let named = PinnedRefs.load(branches: ["v1.0", "origin/main"], refs: ["refs/tags/main"])
    precondition(named.contains("refs/heads/v1.0") && !named.contains("refs/tags/v1.0") && named.contains("refs/heads/origin/main")
                 && !named.contains("refs/remotes/origin/main") && named.contains("refs/tags/main") && !named.contains("refs/heads/main"),
                 "A local branch, a remote branch and a tag of one name must not share a pin")
    let all: Set<String> = ["refs/tags/v1.0", "refs/heads/main", "refs/remotes/origin/main", "refs/heads/v1.0"]
    let stored = PinnedRefs.split(all)
    precondition(stored.branches == ["main", "v1.0"] && stored.refs == ["refs/remotes/origin/main", "refs/tags/v1.0"], "Local pins must be stored by name, the rest as refs")
    precondition(PinnedRefs.load(branches: stored.branches, refs: stored.refs) == all, "Stored pins must read back")
}

@main private struct SidebarTreeLayoutTest {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        checkPinnedGrouping()
        var checks: [[String: Any]] = []
        for width: CGFloat in [240, 280, 320] {
            for dark in [false, true] {
                treeLayoutViews.removeAll()
                let state = TreeLayoutState()
                let host = NSHostingView(rootView: TreeLayoutFixture(state: state).preferredColorScheme(dark ? .dark : .light))
                let bounds = NSRect(x: 0, y: 0, width: width, height: 640)
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

                func shown(_ id: String) -> Bool { treeLayoutViews[id]?.contains { $0.window === window } ?? false }

                func frame(_ id: String) -> NSRect {
                    guard let view = treeLayoutViews[id]?.last(where: { $0.window === window }) else { fatalError("Missing measurement: \(id)") }
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

                // "Pin to top": a loose branch, one from a folder and the current one lead Local branches in name order,
                // under their whole names and with the pin mark; the folder keeps the rest
                state.long = false
                state.current = "feature/checkout"
                state.pinned = ["main", "feature/search", "feature/checkout"]
                settle()
                func top(_ id: String) -> CGFloat { let r = frame(id); return host.isFlipped ? r.minY : host.bounds.height - r.maxY }
                let pinnedNames = ["feature/checkout", "feature/search", "main"]
                close(top("row:" + pinnedNames[0]), top("head:Local branches") + 26, "The first pinned row must stand right under the head")
                for (above, below) in zip(pinnedNames, pinnedNames.dropFirst()) {
                    close(top("row:" + below) - top("row:" + above), 26, "Pinned rows must follow each other in name order")
                }
                precondition(top("label:local-feature") > top("row:main") + 20 && top("row:feature/reviews") > top("label:local-feature"),
                             "The folders must follow the pinned rows, holding what is not pinned")
                for name in pinnedNames {
                    let row = frame("row:" + name), label = frame("label:" + name), pin = frame("pin:" + name)
                    close(row.height, 26, "Pinned row height")
                    close(label.minX, frame("label:local-feature").minX, "A pinned row must align with the folders, out of its own")
                    // the whole name fits at 240 pt in either language: nothing is cut or pushed out
                    let weight: NSFont.Weight = name == state.current ? .semibold : .regular
                    let natural = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight)]).width
                    precondition(label.width >= natural - 1 && pin.minX >= label.maxX && pin.maxX <= row.maxX && row.maxX <= width,
                                 "A pinned row must show its whole name and keep its pin mark inside: row \(row), label \(label), pin \(pin)")
                }
                precondition(shown("current:feature/checkout") && !shown("current:main"), "The pinned current branch must keep its marker")
                precondition(!shown("pin:feature/reviews"), "Only pinned rows carry the pin mark")
                close(frame("label:feature/reviews").minX - frame("label:local-feature").minX, 18, "The folder must keep its unpinned branch")
                _ = try shot("pinned")
                // the filter keeps a pinned match at the top and leaves the other pinned rows out
                state.filter = "search"
                settle()
                precondition(shown("row:feature/search") && !shown("row:main") && !shown("row:feature/checkout") && !shown("label:local-feature"),
                             "The filter must narrow pinned rows by name like any other row")
                close(top("row:feature/search"), top("head:Local branches") + 26, "A pinned match must keep its place at the top")
                state.filter = "e"
                settle()
                precondition(shown("row:feature/checkout") && !shown("row:main") && top("row:feature/search") < top("label:local-feature"),
                             "Pinned matches must stay ahead of the folders")
                state.filter = ""
                // unpinning puts the branch back in its folder at once
                state.pinned.remove("feature/search")
                settle()
                precondition(!shown("pin:feature/search") && top("row:feature/search") > top("label:local-feature"), "Unpinning must put the branch back in its folder")
                close(frame("label:feature/search").minX - frame("label:local-feature").minX, 18, "An unpinned branch must sit one level in, in its folder")

                // a remote branch pinned out of its folder leads its remote under its name there, beside a pinned local
                // branch of the same name; pinned tags lead Tags in name order; a hidden tag keeps its row, greyed, with
                // the eye that shows it again
                state.pinned.insert("feature/search")
                state.pinnedRemotes = ["origin/feature/search"]
                state.pinnedTags = ["v1.9.0", "v2.0.0"]
                state.hiddenTags = ["v1.10.0"]
                settle()
                func mid(_ id: String) -> CGFloat { top(id) + frame(id).height / 2 }
                close(mid("row:origin/feature/search") - mid("label:origin"), 26, "The pinned remote branch must lead its remote")
                close(mid("row:origin/main") - mid("row:origin/feature/search"), 26, "The remote's other branches must follow its pinned one")
                close(mid("label:remote-feature") - mid("row:origin/main"), 26, "The remote's folders must follow its branches")
                close(frame("label:origin/feature/search").minX, frame("label:origin/main").minX, "A pinned remote row must align with its remote's rows, out of its folder")
                close(frame("label:origin/feature/reviews").minX - frame("label:remote-feature").minX, 18, "The folder must keep the remote branches that are not pinned")
                precondition(shown("pin:origin/feature/search") && shown("pin:feature/search") && !shown("pin:origin/main") && !shown("pin:origin/feature/reviews"),
                             "The pinned remote and local branches of one name must carry their own pin marks, and no other remote row")
                let tagOrder = ["v1.9.0", "v2.0.0", "v1.10.0"]
                close(top("row:tag:" + tagOrder[0]), top("head:Tags") + 26, "The first pinned tag must stand right under the head")
                for (above, below) in zip(tagOrder, tagOrder.dropFirst()) {
                    close(top("row:tag:" + below) - top("row:tag:" + above), 26, "Pinned tags must lead in name order, then the rest")
                }
                precondition(shown("pin:tag:v1.9.0") && shown("pin:tag:v2.0.0") && !shown("pin:tag:v1.10.0"), "Only pinned tags carry the pin mark")
                precondition(shown("eye:tag:v1.10.0") && !shown("eye:tag:v1.9.0") && !shown("eye:tag:v2.0.0"), "Only the hidden tag carries the eye")
                close(frame("label:tag:v1.9.0").minX, frame("label:main").minX, "Tag names must align with the branch names")
                for (rowID, labelID, mark, name) in [("row:origin/feature/search", "label:origin/feature/search", "pin:origin/feature/search", "feature/search"),
                                                     ("row:tag:v1.9.0", "label:tag:v1.9.0", "pin:tag:v1.9.0", "v1.9.0"),
                                                     ("row:tag:v2.0.0", "label:tag:v2.0.0", "pin:tag:v2.0.0", "v2.0.0"),
                                                     ("row:tag:v1.10.0", "label:tag:v1.10.0", "eye:tag:v1.10.0", "v1.10.0")] {
                    let row = frame(rowID), label = frame(labelID), markFrame = frame(mark)
                    let natural = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
                    close(row.height, 26, "Pinned and hidden row height")
                    precondition(label.width >= natural - 1 && row.maxX <= width && markFrame.minX >= label.maxX && markFrame.maxX <= row.maxX,
                                 "\(name) must show its whole name and keep its mark inside: row \(row), label \(label), mark \(markFrame)")
                }
                _ = try shot("pinned-all")
                // the filter keeps a pinned match at the top of its own group
                state.filter = "search"
                settle()
                close(mid("row:origin/feature/search") - mid("label:origin"), 26, "A pinned remote match must stay first in its remote")
                precondition(!shown("row:origin/main") && !shown("label:remote-feature") && !shown("head:Tags"), "The filter must leave out what does not match")
                state.filter = "V1"
                settle()
                precondition(!shown("head:Local branches") && !shown("head:Remotes") && !shown("row:tag:v2.0.0"), "Only the matching tags must stay")
                close(top("row:tag:v1.9.0"), top("head:Tags") + 26, "A pinned tag match must stay first")
                close(top("row:tag:v1.10.0") - top("row:tag:v1.9.0"), 26, "The hidden tag must follow the pinned one")
                state.filter = ""
                // unpinning puts the remote branch back in its folder and the tags in their order; shown again, the tag
                // loses the eye
                state.pinnedRemotes = []
                state.pinnedTags = []
                state.hiddenTags = []
                settle()
                close(frame("label:origin/feature/search").minX - frame("label:remote-feature").minX, 18, "An unpinned remote branch must go back to its folder")
                close(top("row:tag:v1.10.0") - top("row:tag:v2.0.0"), 26, "Unpinned tags must go back to their order")
                close(top("row:tag:v1.9.0") - top("row:tag:v1.10.0"), 26, "Unpinned tags must go back to their order")
                precondition(!shown("pin:tag:v1.9.0") && !shown("eye:tag:v1.10.0") && !shown("pin:origin/feature/search"), "Unpinned and shown rows must lose their marks")
                checks.append(["width": width, "theme": dark ? "dark" : "light", "childIndent": 18,
                               "rowHeight": 26, "siblingsAligned": true, "headHeight": 26, "countPills": true, "collapseReopen": true,
                               "field": "28 pt, 10 pt above and below", "filter": true, "emptyForm": true, "longName": true,
                               "pinnedFirst": true, "pinnedRemotesAndTags": true, "hiddenTag": true, "screenshot": screenshot])
                window.orderOut(nil)
            }
        }
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("PASS: the Filter branches field, production branch rows and tree groups align at 240/280/320 points in light/dark, with 18-point nesting, compact 26-point rows, 26-point heads and count pills at the right edge; pinned branches lead Local branches under their whole names and go back to their folder when unpinned, a pinned remote branch leads its remote and pinned tags lead Tags, a hidden tag keeps its row with the eye; the filter opens folded folders, hides what does not match, keeps pinned matches first, shows the empty form and restores the folds. \(output.path)")
    }
}
