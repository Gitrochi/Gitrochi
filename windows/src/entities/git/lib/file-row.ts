import { t } from "@/shared/i18n";
import type { FileChange } from "../model/types";

/** "find.md → search.md" for a rename, "copied from find.md" for a copy; the old folder too when only that changed */
export function renameCaption(change: Pick<FileChange, "path" | "oldPath" | "kind">): string | null {
  if (!change.oldPath || change.oldPath === change.path) return null;
  const name = (path: string) => path.split("/").pop() ?? path;
  if (change.kind === "copied") return t("copied from {0}", name(change.oldPath));
  return `${name(change.oldPath) === name(change.path) ? change.oldPath : name(change.oldPath)} → ${name(change.path)}`;
}
