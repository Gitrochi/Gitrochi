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
  type HubDetail,
  type HubProjectField,
  type HubProjectRow,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
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
}) {
  const [editing, setEditing] = useState(false),
    [title, setTitle] = useState(row.title),
    [body, setBody] = useState(row.body);
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
          onClick={() => {
            ask.cancel?.();
            close();
          }}
        >
          <X size={15} />
        </Button>
      </div>
      <div className="project-inspector-body">
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
                ? t("Draft")
                : kind === "redacted"
                  ? t("Restricted item")
                  : t("Issue")}
            {row.number ? ` #${row.number}` : ""}
          </span>
          {row.archived && <span className="project-tag">{t("Archived")}</span>}
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
                  ask(t("Save draft changes?"), title, async (access) => {
                    await saveHubProjectDraft(access, detail, title, body, row);
                    setEditing(false);
                  })
                }
              >
                <Check size={13} />
                {t("Review and save")}
              </Button>
              <Button
                size="small"
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
            {row.body ? (
              <div className="project-inspector-description">{row.body}</div>
            ) : (
              <p className="hint">{t("No description yet.")}</p>
            )}
          </>
        )}
        {repository && (
          <div className="project-inspector-meta">
            <span>{t("Repository")}</span>
            <strong>{repository}</strong>
          </div>
        )}
        {!!row.assignees?.length && (
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
          {safe(row.url) && (
            <Button size="small" onClick={() => open(row.url)}>
              <ExternalLink size={13} />
              {t("Open in browser")}
            </Button>
          )}
        </div>
        <div className="project-inspector-divider" />
        <h3>{t("Project fields")}</h3>
        {detail.fields.map((field) => (
          <ProjectFieldEditor
            key={`${row.id}:${field.id}:${projectFieldValue(row, field)}`}
            field={field}
            row={row}
            clearable={!gitlab}
            locked={locked || !row.contentID || row.archived === true}
            save={(value) =>
              ask(
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
        {!detail.fields.length && (
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
      </div>
    </aside>
  );
}
function ProjectFieldEditor({
  field,
  row,
  locked,
  clearable,
  save,
}: {
  field: HubProjectField;
  row: HubProjectRow;
  locked: boolean;
  clearable: boolean;
  save: (value: string | null) => void;
}) {
  const original = projectFieldValue(row, field),
    [value, setValue] = useState(original);
  const selectable =
    field.kind === "singleSelect" ||
    field.kind === "iteration" ||
    (!field.kind && field.options.length > 0);
  const supported =
    selectable || ["text", "number", "date"].includes(field.kind ?? "");
  return (
    <label className="project-field-editor">
      <span>{field.name}</span>
      {selectable ? (
        <select
          className="select"
          disabled={locked}
          value={original}
          onChange={(event) => save(event.target.value || null)}
        >
          <option value="" disabled={!clearable}>
            {t("Not set")}
          </option>
          {field.options.map((option) => (
            <option key={option.id} value={option.id}>
              {option.name}
            </option>
          ))}
        </select>
      ) : supported ? (
        <div className="project-field-input">
          <input
            className="input"
            type={
              field.kind === "number"
                ? "number"
                : field.kind === "date"
                  ? "date"
                  : "text"
            }
            value={value}
            disabled={locked}
            onChange={(event) => setValue(event.target.value)}
          />
          <Button
            size="small"
            tip={t("Save field")}
            disabled={
              locked ||
              value === original ||
              (field.kind === "number" &&
                value !== "" &&
                !Number.isFinite(Number(value)))
            }
            onClick={() => save(value || null)}
          >
            <Check size={13} />
          </Button>
        </div>
      ) : (
        <span className="hint">
          {original || t("Manage this field in GitHub")}
        </span>
      )}
    </label>
  );
}
