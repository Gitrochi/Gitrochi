import SwiftUI

struct RepositoryExternalEditorMenu: View {
    let editors: [ExternalEditor]
    let fileAvailable: Bool
    let open: (String, Bool) -> Void
    let refresh: () -> Void

    var body: some View {
        Menu {
            Text("Working copy")
            Text("External editors open the current local file, not the revision preview.")
            Menu("Open file in…") {
                ForEach(editors) { editor in
                    Button(label(editor)) { open(editor.id, true) }.disabled(!editor.available || !fileAvailable)
                }
            }.disabled(!fileAvailable)
            Menu("Open repository in…") {
                ForEach(editors.filter(\.supportsFolders)) { editor in
                    Button(label(editor)) { open(editor.id, false) }.disabled(!editor.available)
                }
            }
            Divider()
            Button("Refresh applications", action: refresh)
        } label: { Image(systemName: "arrow.up.forward.app") }
            .menuStyle(.borderlessButton).fixedSize().help("Open with…").accessibilityLabel("Open with…")
            .accessibilityIdentifier("code-open-with")
    }

    private func label(_ editor: ExternalEditor) -> String { editor.name + (editor.available ? "" : " · " + String(localized: "Not installed")) }
}
