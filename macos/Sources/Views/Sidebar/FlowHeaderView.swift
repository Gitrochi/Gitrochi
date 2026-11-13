import SwiftUI

/// What the area under the flow's header shows
enum FlowWorkspaceTab: Hashable {
    case graph, history, connectedCI
}

/// The selected flow's name, what it is for and its actions, then the tabs. It stays put while the tabs change what
/// is below. One filled button: Run flow, which gives way to a plain Stop while a run of this flow is going.
/// (Windows: the heading and tabs of FlowWorkspace.tsx)
struct FlowHeaderView: View {
    let flow: FlowList.Flow
    /// The run of this flow that is going, which Stop cancels
    let running: FlowRunRow?
    /// This flow's run is being prepared
    let starting: Bool
    let canRun: Bool
    /// The side padding, which follows the width of the workspace
    let inset: CGFloat
    /// A narrow workspace sets the name smaller
    let compact: Bool
    @Binding var tab: FlowWorkspaceTab
    let onEdit: () -> Void
    let onRun: () -> Void
    let onStop: (String) -> Void
    let more: FlowMoreActionsMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { name.frame(maxWidth: .infinity, alignment: .leading); actions }
                    VStack(alignment: .leading, spacing: 10) { name; actions }
                }
                if let description = flow.description, !description.isEmpty {
                    Text(verbatim: description).font(.system(size: 13)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, inset).padding(.top, compact ? 16 : 20)
            tabs.padding(.top, 8)
        }
    }

    private var name: some View {
        Text(verbatim: flow.name).font(.system(size: compact ? 17 : 22, weight: .semibold)).lineLimit(2)
            .accessibilityAddTraits(.isHeader)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(action: onEdit) { Label("Edit flow file…", symbol: "doc") }.buttonStyle(HostedListButtonStyle())
            if let running {
                Button { onStop(running.runId) } label: { Label("Stop", symbol: "stop.fill") }
                    .buttonStyle(HostedListButtonStyle())
                    .help("Stops every step and its child processes, then undoes what was changed")
            } else {
                Button(action: onRun) {
                    HStack(spacing: 6) {
                        if starting { ProgressView().controlSize(.mini) } else { SymbolIcon("play.fill").font(.system(size: 11)) }
                        Text("Run flow")
                    }
                }
                .hostedListFilledButton().disabled(!canRun)
            }
            more
        }
        .fixedSize()
    }

    /// Underline tabs: they switch content, so the label never changes weight and only the 2 pt accent line moves
    private var tabs: some View {
        HStack(spacing: 4) {
            AccountTab(title: String(localized: "Flow"), on: tab == .graph) { tab = .graph }
            AccountTab(title: String(localized: "History"), on: tab == .history) { tab = .history }
            AccountTab(title: String(localized: "Connected CI"), on: tab == .connectedCI) { tab = .connectedCI }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, inset)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioStyle.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flows")
    }
}
