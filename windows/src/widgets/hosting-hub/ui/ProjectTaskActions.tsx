import { useRef, useState } from "react";
import { Archive, ArchiveRestore, ArrowUpDown, Circle, MoreHorizontal, Pencil, Trash2 } from "lucide-react";
import { archiveHubProjectItem, deleteHubProjectItem, moveHubProjectItemPosition, convertHubProjectDraftToIssue, type HubDetail, type HubProjectRow } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { useProjectEdit } from "../model/use-project-edit";
import { projectKind, type ProjectAsk } from "../lib/project-workspace";

export function ProjectTaskActions({ detail, row, gitlab, locked, ask, editDraft, repository, onMoved }: {
  detail: HubDetail;
  row: HubProjectRow;
  gitlab: boolean;
  locked: boolean;
  ask: ProjectAsk;
  editDraft: () => void;
  repository?: string;
  onMoved?: () => void;
}) {
  const edit = useProjectEdit(ask), menu = useRef<HTMLDetailsElement>(null);
  locked ||= edit.busy;
  const localProject = detail.item.data.localProject === true, kind = projectKind(row);
  const [converting, setConverting] = useState(false),
    [target, setTarget] = useState(repository ?? row.repository ?? ""),
    [after, setAfter] = useState("");
  const closeMenu = () => { if (menu.current) menu.current.open = false; };
  if (gitlab || kind === "redacted") return null;
  return (
    <div className="project-task-actions">
      {edit.error && <p className="error-text" role="alert">{edit.error}</p>}
      <div className="project-task-actionbar">
        {kind === "draft" && <Button size="small" disabled={locked || row.archived} onClick={editDraft}>
          <Pencil size={13} />{t(localProject ? "Edit task" : "Edit draft")}
        </Button>}
        <details className="project-task-more" ref={menu} onKeyDown={(event) => {
          if (event.key === "Escape") { closeMenu(); event.preventDefault(); }
        }}>
          <summary aria-label={t("More task actions")}><MoreHorizontal size={15} />{t("More")}</summary>
          <div className="project-task-menu">
            <Button size="small" disabled={locked} onClick={() => {
              closeMenu();
              ask(row.archived ? t("Restore this project item?") : t("Archive this project item?"), row.title,
                (access) => archiveHubProjectItem(access, detail, row, !row.archived));
            }}>{row.archived ? <ArchiveRestore size={13} /> : <Archive size={13} />}{t(row.archived ? "Restore" : "Archive")}</Button>
            <details className="project-order-menu">
              <summary><ArrowUpDown size={13} />{t("Move")}</summary>
              <div className="project-order-editor">
                <select className="select" aria-label={t("Move project item after")} value={after} disabled={locked} onChange={(event) => setAfter(event.target.value)}>
                  <option value="" disabled>{t("Choose a position")}</option>
                  <option value="__top">{t("Top of project")}</option>
                  {detail.rows.filter((value) => value.id !== row.id).map((value) => <option value={value.id} key={value.id}>{t("After: {0}", value.title)}</option>)}
                </select>
                <Button size="small" disabled={locked || !after || (after !== "__top" && !detail.rows.some((value) => value.id === after))} onClick={() => {
                  closeMenu();
                  void edit.run(t("Move this project item?"), row.title, async (access) => {
                    const anchor = detail.rows.find((value) => value.id === after);
                    if (after !== "__top" && !anchor) throw new Error(t("Select a loaded project field and item."));
                    await moveHubProjectItemPosition(access, detail, row, after === "__top" ? null : anchor!);
                    onMoved?.();
                  });
                }}>{t("Move")}</Button>
              </div>
            </details>
            {kind === "draft" && !localProject && <Button size="small" disabled={locked || row.archived} onClick={() => { closeMenu(); setConverting(true); }}><Circle size={13} />{t("Convert draft to issue")}</Button>}
            <Button size="small" kind="danger" disabled={locked} onClick={() => {
              closeMenu();
              ask(t("Remove item from project?"), `${row.title}\n${t(localProject ? "This permanently deletes the task from this local project." : "The issue or pull request stays in its repository.")}`,
                (access) => deleteHubProjectItem(access, detail, row));
            }}><Trash2 size={13} />{t("Remove from project")}</Button>
          </div>
        </details>
      </div>
      {converting && <div className="project-convert-draft">
        <label>{t("Repository (owner/name)")}<input className="input" disabled={locked} value={target} placeholder="owner/name" onChange={(event) => setTarget(event.target.value)} /></label>
        <div className="row">
          <Button size="small" disabled={locked || row.archived || !target.trim()} onClick={() => ask(t("Convert this draft to an issue?"), `${row.title}\n${target}\n${t("This creates an issue in the selected repository and keeps its project fields.")}`, async (access) => {
            await convertHubProjectDraftToIssue(access, detail, row, target);
            setConverting(false);
          })}>{t("Review and convert")}</Button>
          <Button size="small" disabled={locked} onClick={() => { ask.cancel?.(); setConverting(false); }}>{t("Cancel")}</Button>
        </div>
      </div>}
    </div>
  );
}
