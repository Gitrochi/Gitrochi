import SwiftUI

/// Conversion chooses its destination before the shared action review.
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
            if row.kind == .draft && !LocalProjectStore.isLocal(detail.item) {
                Button("Convert to issue…") {
                    destination = repository
                    converting = true
                }
            }
        }.font(.callout)
        .sheet(isPresented: $converting) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Convert draft to issue").font(.system(size: 19, weight: .semibold))
                        Text(row.title).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }.padding(24)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Destination repository").font(.callout.weight(.semibold))
                    TextField("Destination repository", text: $destination, prompt: Text(verbatim: "owner/name"))
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                    Text("Choose the repository where this draft will become an issue.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24).padding(.bottom, 24)
                Divider()
                HStack(spacing: 12) {
                    Spacer()
                    Button("Cancel") { converting = false }.keyboardShortcut(.cancelAction)
                    Button("Review conversion") {
                        let selectedDestination = destination.trimmed
                        converting = false
                        convert(selectedDestination)
                    }.buttonStyle(.borderedProminent).disabled(destination.trimmed.isEmpty).keyboardShortcut(.defaultAction)
                }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
            }.frame(width: 510).background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
