import { Folder, FolderOpen, Lock, Plus, TriangleAlert } from "lucide-react";
import { short } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { displayPath, isTemporaryPath, samePath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { IconButton, showContextMenu } from "@/shared/ui";
import { Section } from "./Section";

export function WorktreeSection({ store }: { store: RepoStore }) {
  return (
    <Section
      id="worktrees"
      title={t("Worktrees")}
      count={store.worktrees.length}
      actions={
        <>
          {store.worktrees.some((w) => w.prunable) && (
            <button className="link" onClick={() => void store.pruneWorktrees()}>
              {t("Clean up")}</button>
          )}
          <IconButton
            small
            icon={<Plus size={13} />}
            tip={t("New worktree")}
            onClick={() => {
              store.sheet = { kind: "addWorktree", branch: null, start: null };
              store.changed();
            }}
          />
        </>
      }
    >
      {store.worktrees.map((w) => {
        const current = samePath(w.path, store.path);
        return (
          <div
            key={w.path}
            className={`side-row ${current ? "current" : ""}`}
            style={{ alignItems: "flex-start" }}
            onDoubleClick={() => void store.switchWorktree(w.path)}
            onContextMenu={(e) =>
              showContextMenu(e, [
                { label: t("Open worktree"), disabled: current, onClick: () => void store.switchWorktree(w.path) },
                { label: t("Open in new tab"), disabled: current, onClick: () => void store.openOrReport(w.path) },
                { label: t("Show in Explorer"), onClick: () => void ipc.reveal(w.path) },
                { label: t("Open in the terminal below"), onClick: () => store.newTerminal(w.path) },
                { label: t("Open in external terminal"), onClick: () => void ipc.openTerminal(w.path) },
                { label: t("Run agent"), onClick: () => void store.startAgent(w.path) },
                { label: t("Copy path"), onClick: () => store.copy(displayPath(w.path)) },
                "divider",
                { label: t("Remove…"), danger: true, disabled: w.isMain || current, onClick: () => store.confirmRemove(w) },
                { label: t("Force remove…"), danger: true, disabled: w.isMain || current, onClick: () => store.confirmRemove(w, true) },
              ])
            }
            data-tip={t("Double-click: open in a new tab")}
          >
            <span className="lead" style={{ marginTop: 2 }}>
              {current ? <FolderOpen size={14} /> : <Folder size={14} />}
            </span>
            <span className="col grow">
              <span className="ellipsis">{w.branch ?? t("Detached HEAD {0}", w.head ? short(w.head) : "")}</span>
              <span className="side-sub ellipsis" style={{ direction: "rtl", textAlign: "left" }}>
                <bdi>{displayPath(w.path)}</bdi>
              </span>
            </span>
            {isTemporaryPath(w.path) && !w.prunable && (
              <span className="chip-warn" data-tip={t("Worktree in a temporary folder — it may break when the folder is deleted on restart")}>
                {t("Temporary")}</span>
            )}
            {w.prunable ? (
              <span style={{ color: "var(--orange)" }} data-tip={t("Worktree whose folder is gone — remove it with 'Clean up'")}>
                <TriangleAlert size={13} />
              </span>
            ) : (
              w.locked && (
                <span className="muted" data-tip={t("Locked worktree")}>
                  <Lock size={12} />
                </span>
              )
            )}
          </div>
        );
      })}
    </Section>
  );
}
