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
    var remoteExpanded = true
    var localFolderExpanded = true
    var remoteFolderExpanded = true
}

private struct TreeLayoutFixture: View {
    @Bindable var state: TreeLayoutState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Branches").font(.headline).padding(.horizontal, 10).padding(.vertical, 12)
            section("Local branches 4") {
                branch("main", current: true)
                DisclosureGroup(isExpanded: $state.localFolderExpanded) {
                    branch("feature/checkout", label: "checkout")
                    branch("feature/reviews", label: "reviews")
                    branch("feature/search", label: "search")
                } label: {
                    groupLabel("feature", icon: "folder", count: 3, id: "local-feature")
                }
                .disclosureGroupStyle(SidebarTreeGroup())
            }
            section("Worktrees 2") {
                worktree(Self.mainWorktree, branch: "main", current: true)
                worktree(Self.searchWorktree, branch: "feature/search")
            }
            section("Remotes 4") {
                DisclosureGroup(isExpanded: $state.remoteExpanded) {
                    branch("origin/main", remote: true)
                    DisclosureGroup(isExpanded: $state.remoteFolderExpanded) {
                        branch("origin/feature/checkout", label: "checkout", remote: true)
                        branch("origin/feature/reviews", label: "reviews", remote: true)
                        branch("origin/feature/search", label: "search", remote: true)
                    } label: {
                        groupLabel("feature", icon: "folder", count: 3, id: "remote-feature")
                    }
                    .disclosureGroupStyle(SidebarTreeGroup())
                } label: {
                    groupLabel("origin", icon: "cloud", count: 4, id: "origin")
                }
                .disclosureGroupStyle(SidebarTreeGroup())
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).frame(width: 10)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            VStack(alignment: .leading, spacing: 0, content: content).padding(.horizontal, 6)
        }
        .padding(.top, 6)
    }

    private func groupLabel(_ text: String, icon: String, count: Int, id: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                .background(TreeLayoutProbe(identifier: "icon:" + id))
            Text(text).lineLimit(1)
                .background(TreeLayoutProbe(identifier: "label:" + id))
            Spacer(minLength: 4)
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    static let mainWorktree = NSHomeDirectory() + "/Projects/shop-web"
    static let searchWorktree = NSHomeDirectory() + "/Projects/shop-web-search"

    private func worktree(_ path: String, branch: String, current: Bool = false) -> some View {
        WorktreeRow(worktree: Worktree(path: path, head: "fixture", branch: branch, isMain: current, locked: false, prunable: false),
                    current: current)
            .sidebarTreeRow()
            .background(TreeLayoutProbe(identifier: "row:" + path))
    }

    private func branch(_ name: String, label: String? = nil, current: Bool = false, remote: Bool = false) -> some View {
        let branch = Branch(name: name, target: "fixture", upstream: nil, ahead: current ? 1 : 0,
                            behind: 0, upstreamGone: false, isCurrent: current, isRemote: remote)
        return BranchRow(branch: branch, label: label, toggleHidden: current ? nil : {})
            .sidebarTreeRow()
            .background(TreeLayoutProbe(identifier: "row:" + name))
    }
}

@main private struct SidebarTreeLayoutTest {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var checks: [[String: Any]] = []
        for width: CGFloat in [240, 320] {
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

                func frame(_ id: String) -> NSRect {
                    guard let view = treeLayoutViews[id], view.window === window else { fatalError("Missing measurement: \(id)") }
                    return view.convert(view.bounds, to: host)
                }

                func close(_ value: CGFloat, _ expected: CGFloat, _ message: String) {
                    precondition(abs(value - expected) <= 1, "\(message): \(value), expected \(expected)")
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
                for path in [TreeLayoutFixture.mainWorktree, TreeLayoutFixture.searchWorktree] {
                    close(frame("icon:" + path).minX, frame("icon:main").minX, "Worktree and branch icons must align")
                    close(frame("label:" + path).minX, frame("label:main").minX, "Worktree and branch labels must align")
                    precondition(frame("row:" + path).height >= 26 - 1, "Worktree rows must keep the tree row height")
                }

                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { fatalError("No tree bitmap") }
                host.cacheDisplay(in: bounds, to: bitmap)
                let name = "sidebar-tree-\(Int(width))-\(dark ? "dark" : "light").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))

                state.remoteFolderExpanded = false
                settle()
                precondition(treeLayoutViews["row:origin/feature/checkout"]?.window == nil, "Collapsed folders must remove their children")
                state.remoteFolderExpanded = true
                settle()
                close(frame("icon:origin/feature/checkout").minX - frame("icon:remote-feature").minX, 18,
                      "Reopening folders must retain indentation")
                state.remoteExpanded = false
                settle()
                precondition(treeLayoutViews["row:origin/main"]?.window == nil, "Collapsed remotes must remove their children")
                checks.append(["width": width, "theme": dark ? "dark" : "light", "childIndent": 18,
                               "rowHeight": 26, "siblingsAligned": true, "worktreesAligned": true, "collapseReopen": true, "screenshot": name])
                window.orderOut(nil)
            }
        }
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("PASS: production branch rows, worktree rows and tree groups align at 240/320 points in light/dark, with 18-point nesting and compact 26-point rows. \(output.path)")
    }
}
