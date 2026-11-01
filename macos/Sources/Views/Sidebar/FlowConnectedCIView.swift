import SwiftUI

/// Connected provider configuration and the existing pipeline/job/log controls stay in the Flows workspace.
struct FlowConnectedCIView: View {
    let repo: URL
    var body: some View {
        VStack(spacing: 0) {
            FlowConnectionsView(repo: repo)
            Divider()
            ActionsWorkspacePanel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
