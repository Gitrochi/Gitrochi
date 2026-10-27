import { useProjectEdit } from "../model/use-project-edit";
import { useState } from "react";
import {
  Check,
  Circle,
  ExternalLink,
  GitBranch,
  GitPullRequest,
  Pencil,
  X,
} from "lucide-react";
import {
  moveHubProjectItem,
  projectTaskBranches,
  saveHubProjectDraft,
  updateHubProjectField,
  type HubAccess,
  type HubDetail,
  type HubProjectRow,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { ProjectFieldEditor } from "./ProjectFieldEditor";
import { ProjectTaskConversation } from "./ProjectTaskConversation";
import { ProjectTaskActions } from "./ProjectTaskActions";
import {
  projectFieldValue,
  type ProjectAsk,
  type ProjectLocalActions,
  projectKind,
  projectRepository,
} from "../lib/project-workspace";

export function ProjectInspector({
  detail,
  row,
  locked,
  gitlab,
  open,
  safe,
  ask,
  close,
  local,
  onMoved,
  readAccess,
}: {
  detail: HubDetail;
  row: HubProjectRow;
  locked: boolean;
  gitlab: boolean;
  open: (url: string) => void;
  safe: (url: string) => boolean;
  ask: ProjectAsk;
  close: () => void;
  local?: ProjectLocalActions;
  onMoved?: () => void;
  readAccess?: () => Promise<HubAccess>;
}) {
  const edit = useProjectEdit(ask);
  locked ||= edit.busy;
  const [editing, setEditing] = useState(false),
    [title, setTitle] = useState(row.title),
    [body, setBody] = useState(row.body);
  const localProject = detail.item.data.localProject === true;
  const editableFields = detail.fields.filter((field) => !/^(title|repository|labels|assignees)$/i.test(field.name) || field.id === "local-assignees");
  const propertyRank = (id: string, name: string) => /status|state/i.test(id + name) ? 0 : /priority/i.test(id + name) ? 1 : /start/i.test(id + name) ? 2 : /due|target/i.test(id + name) ? 3 : 4;
  editableFields.sort((a, b) => propertyRank(a.id, a.name) - propertyRank(b.id, b.name));
  const kind = projectKind(row),
    repository = projectRepository(row),
    matchesLocal =
      !!local &&
      (kind === "draft" ||
        (repository.toLocaleLowerCase() ===
          local.repository.toLocaleLowerCase() &&
          (() => {
            try {
              return (
                new URL(row.url).hostname.toLocaleLowerCase() ===
                local.host.toLocaleLowerCase()
              );
            } catch {
              return false;
            }
          })()));
  const linkedBranches =
    matchesLocal && local?.path
      ? projectTaskBranches(
          local.path,
          row.id,
          local.repository,
          local.host,
        ).filter((branch) => local.branches?.includes(branch))
      : [];
  return (
    <aside className="project-inspector" aria-label={t("Task details")}>
      <div className="project-inspector-heading">
        <span>{t("Task details")}</span>
        <Button
          size="small"
          tip={t("Close task details")}
          aria-label={t("Close task details")}
          disabled={edit.busy}
          onClick={() => {
            ask.cancel?.();
            close();
          }}
        >
          <X size={15} />
        </Button>
      </div>
      <div className="project-inspector-body">
        {edit.error && <p className="error-text" role="alert">{edit.error}</p>}
        <div className="project-task-kind">
          {kind === "pullRequest" ? (
            <GitPullRequest size={15} />
          ) : kind === "draft" ? (
            <Pencil size={15} />
          ) : (
            <Circle size={15} />
          )}
          <span>
            {kind === "pullRequest"
              ? t("Pull request")
              : kind === "draft"
                ? t(detail.item.data.localProject === true ? "Task" : "Draft")
                : kind === "redacted"
                  ? t("Restricted item")
                  : t("Issue")}
            {row.number ? ` #${row.number}` : ""}
          </span>
          {row.archived && <span className="project-tag">{t("Archived")}</span>}
          {!localProject && /^(open|closed|merged)$/i.test(row.state ?? "") && <span className={`project-task-state ${/open/i.test(row.state ?? "") ? "open" : "closed"}`}>{t(/^merged$/i.test(row.state ?? "") ? "Merged" : /^closed$/i.test(row.state ?? "") ? "Closed" : "Open")}</span>}
        </div>
        {editing ? (
          <div className="project-editor">
            <label>
              {t("Title")}
              <input
                className="input"
                value={title}
                disabled={locked}
                onChange={(event) => setTitle(event.target.value)}
              />
            </label>
            <label>
              {t("Description")}
              <textarea
                className="textarea"
                rows={8}
                value={body}
                disabled={locked}
                onChange={(event) => setBody(event.target.value)}
              />
            </label>
            <div className="row">
              <Button
                size="small"
                kind="primary"
                disabled={locked || !title.trim()}
                onClick={() =>
                  edit.run(
                    t(
                      detail.item.data.localProject === true
                        ? "Save task changes?"
                        : "Save draft changes?",
                    ),
                    title,
                    async (access) => {
                      await saveHubProjectDraft(
                        access,
                        detail,
                        title,
                        body,
                        row,
                      );
                      setEditing(false);
                    },
                  )
                }
              >
                <Check size={13} />
                {t("Save changes")}
              </Button>
              <Button
                size="small"
                disabled={edit.busy}
                onClick={() => {
                  ask.cancel?.();
                  setEditing(false);
                }}
              >
                {t("Cancel")}
              </Button>
            </div>
          </div>
        ) : (
          <>
            <h2>{row.title}</h2>
          </>
        )}
        {repository && (
          <div className="project-inspector-meta">
            <span>{t("Repository")}</span>
            <strong>{repository}</strong>
          </div>
        )}
        {!!row.assignees?.length && !detail.fields.some((field) => field.id === "local-assignees") && (
          <div className="project-inspector-meta">
            <span>{t("Assignees")}</span>
            <div className="project-people">
              {row.assignees.map((name) => (
                <span className="project-tag" key={name}>
                  @{name}
                </span>
              ))}
            </div>
          </div>
        )}
        {!!row.labels?.length && (
          <div className="project-labels">
            {row.labels.map((label) => (
              <span className="project-tag" key={label}>
                {label}
              </span>
            ))}
          </div>
        )}
        {!!linkedBranches.length && (
          <div className="project-inspector-meta">
            <span>{t("Linked local branches")}</span>
            <div className="project-people">
              {linkedBranches.map((branch) => (
                <span className="project-tag" key={branch}>
                  <GitBranch size={11} />
                  {branch}
                </span>
              ))}
            </div>
          </div>
        )}
        <div className="project-native-actions">
          {matchesLocal && local?.onStartTask && kind !== "redacted" && (
            <Button
              kind="primary"
              disabled={locked || row.archived}
              onClick={() => local.onStartTask!(row)}
            >
              <GitBranch size={14} />
              {kind === "draft"
                ? t("Start work in {0}", local!.repository)
                : t("Start work on this task")}
            </Button>
          )}
          {matchesLocal && kind === "pullRequest" && local?.onOpenRequest && (
            <Button disabled={locked} onClick={() => local.onOpenRequest!(row)}>
              <GitPullRequest size={14} />
              {t("Review in Gitrochi")}
            </Button>
          )}
          {safe(row.url) && (localProject || !["issue", "pullRequest"].includes(kind)) && (
            <Button size="small" onClick={() => open(row.url)}>
              <ExternalLink size={13} />
              {t("Open in browser")}
            </Button>
          )}
        </div>
        <div className="project-inspector-divider" />
        <h3>{t("Properties")}</h3>
        <div className="project-property-grid">
        {editableFields.map((field) => (
          <ProjectFieldEditor
            key={`${row.id}:${field.id}:${projectFieldValue(row, field)}`}
            field={field}
            row={row}
            clearable={
              !gitlab &&
              !(
                detail.item.data.localProject === true &&
                ["local-status", "local-priority"].includes(field.id)
              )
            }
            locked={locked || !row.contentID || row.archived === true}
            save={(value) =>
              edit.run(
                t("Update project field?"),
                `${row.title}\n${field.name}: ${value === null ? t("Not set") : (field.options.find((option) => option.id === value)?.name ?? value)}`,
                (access) =>
                  gitlab
                    ? moveHubProjectItem(
                        access,
                        detail,
                        row,
                        field,
                        value ?? "",
                      )
                    : updateHubProjectField(access, detail, row, field, value),
              )
            }
          />
        ))}
        </div>
        {!editableFields.length && (
          <p className="hint">{t("No project fields are available.")}</p>
        )}
        <ProjectTaskActions
          detail={detail}
          row={row}
          gitlab={gitlab}
          locked={locked}
          ask={ask}
          repository={local?.repository}
          onMoved={onMoved}
          editDraft={() => {
            setTitle(row.title);
            setBody(row.body);
            setEditing(true);
          }}
        />
        {!editing && <ProjectTaskConversation row={row} localProject={localProject} locked={locked} open={open} safe={safe} readAccess={readAccess} ask={ask} />}
      </div>
    </aside>
  );
}
