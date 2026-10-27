import { useState } from "react";
import { Archive, ArchiveRestore, CheckSquare, Trash2, X } from "lucide-react";
import {
  localProjects,
  archiveHubProjectItem,
  deleteHubProjectItem,
  moveHubProjectItem,
  updateHubProjectField,
  type HubAccess,
  type HubDetail,
  type HubProjectRow,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { runProjectBatch, type ProjectAsk } from "../lib/project-workspace";
export function ProjectBulkActions({
  detail,
  rows,
  visible,
  gitlab,
  locked,
  ask,
  selectAll,
  done,
}: {
  detail: HubDetail;
  rows: HubProjectRow[];
  visible: number;
  gitlab: boolean;
  locked: boolean;
  ask: ProjectAsk;
  selectAll: () => void;
  done: () => void;
}) {
  const fields = detail.fields.filter(
      (field) =>
        field.kind === "singleSelect" ||
        field.kind === "iteration" ||
        (!field.kind && field.options.length) ||
        ["text", "number", "date"].includes(field.kind ?? ""),
    ),
    [fieldID, setFieldID] = useState(""),
    [option, setOption] = useState("");
  const field = fields.find((value) => value.id === fieldID) ?? fields[0];
  const selectable =
    field?.kind === "singleSelect" ||
    field?.kind === "iteration" ||
    (!field?.kind && !!field?.options.length);
  const act = (
    title: string,
    work: (access: HubAccess, row: HubProjectRow) => Promise<unknown>,
    localWork: () => Promise<unknown>,
  ) =>
    ask(
      title,
      `${t("{0} selected items", rows.length)}\n${rows.map((row) => row.title).join("\n")}\n\n${title === t("Remove selected items from project?") ? t(detail.item.data.localProject === true ? "These tasks will be permanently removed from this device." : "The issues and pull requests stay in their repositories.") : t("Review the project and affected items before applying this change.")}`,
      async (access) => {
        if (access.local) await localWork();
        else await runProjectBatch(access, rows, work);
        done();
      },
    );
  return (
    <div
      className="project-bulk-actions"
      aria-label={t("Bulk project actions")}
    >
      <span>
        <CheckSquare size={15} />
        <strong>{t("{0} selected", rows.length)}</strong>
      </span>
      <Button
        size="small"
        disabled={locked || visible === 0}
        onClick={selectAll}
      >
        {t("Select visible")}
      </Button>
      {field && (
        <>
          <select
            className="select"
            aria-label={t("Bulk field")}
            disabled={locked}
            value={field.id}
            onChange={(event) => {
              setFieldID(event.target.value);
              setOption("");
            }}
          >
            {fields.map((value) => (
              <option value={value.id} key={value.id}>
                {value.name}
              </option>
            ))}
          </select>
          {selectable ? (
            <select
              className="select"
              aria-label={t("Bulk field value")}
              disabled={locked}
              value={option}
              onChange={(event) => setOption(event.target.value)}
            >
              <option value="" disabled>
                {t("Choose a value")}
              </option>
              {!gitlab && detail.item.data.localProject !== true && (
                <option value="__clear">{t("Clear field")}</option>
              )}
              {field.options.map((value) => (
                <option key={value.id} value={value.id}>
                  {value.name}
                </option>
              ))}
            </select>
          ) : (
            <input
              className="input"
              aria-label={t("Bulk field value")}
              type={
                field.kind === "number"
                  ? "number"
                  : field.kind === "date"
                    ? "date"
                    : "text"
              }
              disabled={locked}
              value={option}
              placeholder={t("Choose a value")}
              onChange={(event) => setOption(event.target.value)}
            />
          )}
          <Button
            size="small"
            disabled={
              locked ||
              !rows.length ||
              !option ||
              (field.kind === "number" && !Number.isFinite(Number(option)))
            }
            onClick={() =>
              act(
                t("Update selected project items?"),
                (access, row) =>
                  gitlab
                    ? moveHubProjectItem(access, detail, row, field, option)
                    : updateHubProjectField(
                        access,
                        detail,
                        row,
                        field,
                        option === "__clear" ? null : option,
                      ),
                () =>
                  localProjects.updateFields(
                    detail,
                    rows,
                    field,
                    option === "__clear" ? null : option,
                  ),
              )
            }
          >
            {t("Apply field")}
          </Button>
          {!gitlab && !selectable && (
            <Button
              size="small"
              disabled={locked || !rows.length}
              onClick={() =>
                act(
                  t("Update selected project items?"),
                  (access, row) =>
                    updateHubProjectField(access, detail, row, field, null),
                  () => localProjects.updateFields(detail, rows, field, null),
                )
              }
            >
              {t("Clear field")}
            </Button>
          )}
        </>
      )}
      {!gitlab && (
        <>
          <Button
            size="small"
            disabled={locked || !rows.length}
            onClick={() =>
              act(
                t("Archive selected project items?"),
                (access, row) =>
                  archiveHubProjectItem(access, detail, row, true),
                () => localProjects.archiveMany(detail, rows, true),
              )
            }
          >
            <Archive size={13} />
            {t("Archive")}
          </Button>
          <Button
            size="small"
            disabled={locked || !rows.length}
            onClick={() =>
              act(
                t("Restore selected project items?"),
                (access, row) =>
                  archiveHubProjectItem(access, detail, row, false),
                () => localProjects.archiveMany(detail, rows, false),
              )
            }
          >
            <ArchiveRestore size={13} />
            {t("Restore")}
          </Button>
          <Button
            size="small"
            kind="danger"
            disabled={locked || !rows.length}
            onClick={() =>
              act(
                t("Remove selected items from project?"),
                (access, row) => deleteHubProjectItem(access, detail, row),
                () => localProjects.removeMany(detail, rows),
              )
            }
          >
            <Trash2 size={13} />
            {t("Remove")}
          </Button>
        </>
      )}
      <Button
        size="small"
        tip={t("End selection")}
        aria-label={t("End selection")}
        onClick={() => {
          ask.cancel?.();
          done();
        }}
      >
        <X size={14} />
      </Button>
    </div>
  );
}
