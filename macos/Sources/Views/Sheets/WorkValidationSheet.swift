import SwiftUI

struct WorkValidationSheet: View {
    let store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var tab = "verification"
    @ViewState private var stamp = ""
    @ViewState private var evidence: [WorkFlowEvidence] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Work validation").font(.title3.weight(.semibold))
            Picker("Work validation", selection: $tab) {
                Text("Verification evidence").tag("verification")
                Text("Team overlap evidence").tag("team")
                Text("Agent handoff").tag("agents")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "verification", let url = store.url {
                        VerificationPanel(store: store, flows: FlowCenter.shared.store(for: url), stamp: $stamp, evidence: $evidence)
                    } else if tab == "team" { TeamHubPanel(store: store) }
                    else { AgentHandoffPanel(store: store, stamp: stamp, evidence: evidence) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(minWidth: 700, idealWidth: 850, minHeight: 500, idealHeight: 680)
        .onChange(of: store.url) { _, _ in stamp = ""; evidence = [] }
        .onChange(of: store.headHash) { _, _ in stamp = ""; evidence = [] }
    }
}
