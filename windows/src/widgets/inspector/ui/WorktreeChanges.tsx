import { GitBranch } from "@/shared/icons";
import { type DiffSource, emptyStatus, renameCaption, sameDiffSource, StatusBadge, statusFiles } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { displayPath, samePath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, FileRow } from "@/shared/ui";

/** Another worktree's row in the graph: its uncommitted files, read-only (GitKraken's worktree WIP node) */
export function WorktreeChanges({ store, path }: { store: RepoStore; path: string }) {
  const w = store.worktrees.find((x) => samePath(x.path, path));
  const files = statusFiles(store.worktreeStatus[path] ?? emptyStatus());
  return (
    <div className="col grow" style={{ height: "100%" }}>
      <div className="panel-head">
        <GitBranch size={15} className="muted" />
        <span className="ellipsis" style={{ fontWeight: 600 }}>
          {w?.branch ?? t("Detached HEAD")}
        </span>
        <span className="spacer" />
        <span className="muted">{t("Worktree")}</span>
      </div>
      <div className="panel-scroll">
        <span className="muted ellipsis selectable">{displayPath(path)}</span>
        <div className="row" style={{ flexWrap: "wrap" }}>
          <Button kind="primary" onClick={() => void store.switchWorktree(path)}>
            {t("Open worktree")}
          </Button>
          <Button onClick={() => void store.openOrReport(path)}>{t("Open in new tab")}</Button>
        </div>
        <span className="muted" style={{ fontSize: 11.5 }}>
          {t("Uncommitted changes in this worktree. Open it to stage and commit.")}
        </span>
        <div className="col worktree-files">
          <span style={{ fontWeight: 600 }}>{t("Changed files {0}", files.length)}</span>
          {files.map((c) => {
            const source: DiffSource = { kind: "worktree", path, change: c };
            return <FileRow key={c.path} path={c.path} oldPath={c.oldPath} badge={<StatusBadge kind={c.kind} />} rename={renameCaption(c)} selected={sameDiffSource(store.diffSource, source)} open={() => store.openDiff(source)} />;
          })}
          {!files.length && <span className="muted">{t("No changes")}</span>}
        </div>
      </div>
    </div>
  );
}
