import SwiftUI

/// Home shows only explicitly opened repositories; checks start on user action.
struct ReleaseOverview: View {
    private let portfolio = ReleasePortfolio.shared
    private var sources: [RepoStore] { Workspace.shared.openRepositories.filter { $0.target != nil } }
    private var checking: Bool { sources.contains { portfolio.entry($0).status == "Checking releases…" } }
    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                WorkbenchFlow(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) { Text("Repository releases").font(.headline); Text("Check versions across your open repositories.").font(.caption).foregroundStyle(.secondary) }
                    Button("Check releases") { Task { await portfolio.refresh(sources) } }.disabled(checking)
                    Button { Task { await portfolio.refresh(sources, force: true) } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityLabel("Refresh").disabled(checking)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(sources) { source in summaryCard(source) }
                }
            }.padding(18).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func summaryCard(_ source: RepoStore) -> some View {
        let summary = portfolio.entry(source), sorted = ReleaseCatalog.ordered(summary.page?.items ?? [])
        let stable = sorted.first { ReleaseCatalog.state($0) == "Stable" }, prerelease = sorted.first { ReleaseCatalog.state($0) == "Prerelease" }
        let packages = Set(sorted.map(ReleaseCatalog.family))
        return VStack(alignment: .leading, spacing: 9) {
            Text(source.target?.path ?? source.name).font(.callout.weight(.semibold)).textSelection(.enabled)
            Text((source.target?.host ?? "") + " · @" + (source.hostingAccount?.username ?? "—")).font(.caption).foregroundStyle(.secondary)
            Text(LocalizedStringKey(summary.status)).font(.caption).foregroundStyle(.secondary)
            if summary.status == "Ready" {
                if packages.count > 1 { Text("Multiple packages; open releases to choose one.").font(.caption).foregroundStyle(.secondary) }
                else {
                    Text(summary.page?.more == true ? String(localized: "Newest loaded stable") : String(localized: "Latest stable by date")).font(.caption).foregroundStyle(.secondary)
                    Text(stable.map(ReleaseCatalog.tag) ?? "—").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    if let stable { Text(String(ReleaseCatalog.date(stable).prefix(10))).font(.caption).foregroundStyle(.secondary) }
                    if let prerelease { Text(String(localized: "Prerelease") + ": " + ReleaseCatalog.tag(prerelease)).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let error = summary.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let checked = summary.checkedAt { Text(String(localized: "Last checked") + ": " + checked.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            Button("Open releases") {
                source.navigate(.releases)
                source.window?.tabGroup?.selectedWindow = source.window
                source.window?.makeKeyAndOrderFront(nil)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.background, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }
}
