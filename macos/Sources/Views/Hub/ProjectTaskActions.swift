import SwiftUI

/// Shared task ordering and draft conversion use the same confirmation path as field edits.
struct ProjectTaskActions: View {
    let detail: HubDetail
    let row: HubProjectRow
    let repository: String
    let reorder: (HubProjectRow?) -> Void
    let convert: (String) -> Void
    @ViewState private var converting = false
    @ViewState private var destination = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Move to top…") { reorder(nil) }
            Menu("Move after…") {
                ForEach(detail.rows.filter { $0.id != row.id && !$0.archived }) { other in
                    Button(other.title) { reorder(other) }
                }
            }.menuStyle(.borderlessButton)
            if row.kind == .draft {
                Button("Convert to issue…") {
                    destination = repository
                    converting = true
                }
            }
        }.font(.callout)
        .sheet(isPresented: $converting) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Convert draft to issue?").font(.title2.bold())
                Text(row.title).foregroundStyle(.secondary)
                TextField("Destination repository", text: $destination, prompt: Text(verbatim: "owner/name"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { converting = false }.keyboardShortcut(.cancelAction)
                    Button("Review and save") {
                        converting = false
                        convert(destination)
                    }.buttonStyle(.borderedProminent).disabled(destination.trimmed.isEmpty)
                }
            }.padding(24).frame(width: 460)
        }
    }
}
