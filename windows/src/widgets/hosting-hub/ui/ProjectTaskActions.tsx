import { useState } from "react";
import {
  Archive,
  ArchiveRestore,
  ArrowUpDown,
  Circle,
  Pencil,
  Trash2,
} from "lucide-react";
import {
  archiveHubProjectItem,
  deleteHubProjectItem,
  moveHubProjectItemPosition,
  convertHubProjectDraftToIssue,
  type HubDetail,
  type HubProjectRow,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { projectKind, type ProjectAsk } from "../lib/project-workspace";
export function ProjectTaskActions({
  detail,
  row,
  gitlab,
  locked,
  ask,
  editDraft,
  repository,
  onMoved,
}: {
  detail: HubDetail;
  row: HubProjectRow;
  gitlab: boolean;
  locked: boolean;
  ask: ProjectAsk;
  editDraft: () => void;
  repository?: string;
  onMoved?: () => void;
}) {
  const kind = projectKind(row),
    [converting, setConverting] = useState(false),
    [target, setTarget] = useState(repository ?? row.repository ?? ""),
    [after, setAfter] = useState("");
  if (gitlab || kind === "redacted") return null;
  return (
    <div className="project-task-actions">
      <div className="project-order-editor">
        <label>
          {t("Project order")}
          <select
            className="select"
            aria-label={t("Move project item after")}
            value={after}
            disabled={locked}
            onChange={(event) => setAfter(event.target.value)}
          >
            <option value="" disabled>
              {t("Choose a position")}
            </option>
            <option value="__top">{t("Top of project")}</option>
            {detail.rows
              .filter((value) => value.id !== row.id)
              .map((value) => (
                <option value={value.id} key={value.id}>
                  {t("After: {0}", value.title)}
                </option>
              ))}
          </select>
        </label>
        <Button
          size="small"
          disabled={
            locked ||
            !after ||
            (after !== "__top" &&
              !detail.rows.some((value) => value.id === after))
          }
          onClick={() =>
            ask(
              t("Move this project item?"),
              `${row.title}\n${after === "__top" ? t("Top of project") : t("After: {0}", detail.rows.find((value) => value.id === after)?.title ?? "")}`,
              async (access) => {
                const anchor = detail.rows.find((value) => value.id === after);
                if (after !== "__top" && !anchor)
                  throw new Error(t("Select a loaded project field and item."));
                await moveHubProjectItemPosition(
                  access,
                  detail,
                  row,
                  after === "__top" ? null : anchor!,
                );
                onMoved?.();
              },
            )
          }
        >
          <ArrowUpDown size={13} />
          {t("Move")}
        </Button>
      </div>
      {kind === "draft" && (
        <div className="project-convert-draft">
          {converting ? (
            <>
              <label>
                {t("Repository (owner/name)")}
                <input
                  className="input"
                  disabled={locked}
                  value={target}
                  placeholder="owner/name"
                  onChange={(event) => setTarget(event.target.value)}
                />
              </label>
              <div className="row">
                <Button
                  size="small"
                  disabled={locked || row.archived || !target.trim()}
                  onClick={() =>
                    ask(
                      t("Convert this draft to an issue?"),
                      `${row.title}\n${target}\n${t("This creates an issue in the selected repository and keeps its project fields.")}`,
                      async (access) => {
                        await convertHubProjectDraftToIssue(
                          access,
                          detail,
                          row,
                          target,
                        );
                        setConverting(false);
                      },
                    )
                  }
                >
                  {t("Review and convert")}
                </Button>
                <Button
                  size="small"
                  disabled={locked}
                  onClick={() => {
                    ask.cancel?.();
                    setConverting(false);
                  }}
                >
                  {t("Cancel")}
                </Button>
              </div>
            </>
          ) : (
            <Button
              size="small"
              disabled={locked || row.archived}
              onClick={() => setConverting(true)}
            >
              <Circle size={13} />
              {t("Convert draft to issue")}
            </Button>
          )}
        </div>
      )}
      <div className="project-item-actions">
        {kind === "draft" && (
          <Button
            size="small"
            disabled={locked}
            onClick={() => {
              editDraft();
            }}
          >
            <Pencil size={13} />
            {t("Edit draft")}
          </Button>
        )}
        <Button
          size="small"
          disabled={locked}
          onClick={() =>
            ask(
              row.archived
                ? t("Restore this project item?")
                : t("Archive this project item?"),
              row.title,
              (access) =>
                archiveHubProjectItem(access, detail, row, !row.archived),
            )
          }
        >
          {row.archived ? <ArchiveRestore size={13} /> : <Archive size={13} />}{" "}
          {row.archived ? t("Restore") : t("Archive")}
        </Button>
        <Button
          size="small"
          kind="danger"
          disabled={locked}
          onClick={() =>
            ask(
              t("Remove item from project?"),
              `${row.title}\n${t("The issue or pull request stays in its repository.")}`,
              (access) => deleteHubProjectItem(access, detail, row),
            )
          }
        >
          <Trash2 size={13} />
          {t("Remove from project")}
        </Button>
      </div>
    </div>
  );
}
