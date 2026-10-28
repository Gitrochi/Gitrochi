import { ipc, type ExternalEditorID } from "@/shared/api";

export type { ExternalEditor, ExternalEditorID } from "@/shared/api";

/** Opens native-validated working-copy paths without executing repository commands. */
export const externalEditors = {
  list: () => ipc.externalEditors(),
  open: (repo: string, editorID: ExternalEditorID, file?: string) => ipc.openExternalEditor(repo, editorID, file),
};
