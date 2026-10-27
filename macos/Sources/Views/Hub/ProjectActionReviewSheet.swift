import SwiftUI

/// Consequential project actions keep their scope and recovery instructions beside the final button.
struct ProjectActionReviewSheet: View {
    let title: String
    let project: String
    let summary: String
    let items: [String]
    let actionTitle: String
    let destructive: Bool
    let submit: () async -> String?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var saving = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: destructive ? "trash" : "checklist").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(destructive ? Color.red : Color.accentColor).frame(width: 44, height: 44)
                    .background((destructive ? Color.red : Color.accentColor).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(24)
            VStack(alignment: .leading, spacing: 12) {
                if !project.isEmpty {
                    HStack { Label("Project", systemImage: "rectangle.3.group").foregroundStyle(.secondary); Spacer(); Text(project).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.trailing) }.font(.callout)
                }
                if !items.isEmpty {
                    Divider()
                    if items.count <= 3 { itemRows }
                    else { ScrollView { itemRows }.frame(height: min(200, CGFloat(items.count) * 35 + 6)) }
                }
            }.padding(16).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24).padding(.bottom, 20)
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 18)
            }
            Divider()
            HStack(spacing: 12) {
                if saving { ProgressView().controlSize(.small); Text("Saving changes…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(role: destructive ? .destructive : nil) {
                    guard !saving else { return }; saving = true; error = nil
                    Task { let result = await submit(); saving = false; if let result { error = result } else { dismiss() } }
                } label: { Text(actionTitle).frame(minWidth: 90) }
                    .buttonStyle(.borderedProminent).tint(destructive ? .red : .accentColor).keyboardShortcut(.defaultAction).disabled(saving)
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 540).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    private var itemRows: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary).padding(.top, 6)
                    Text(item).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).help(item)
                    Spacer(minLength: 0)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
