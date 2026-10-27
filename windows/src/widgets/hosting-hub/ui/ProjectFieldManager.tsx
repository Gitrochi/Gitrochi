import { useProjectEdit } from "../model/use-project-edit";
import { useState } from "react";
import { Plus, Trash2, X } from "lucide-react";
import {
  deleteHubProjectCustomField,
  saveHubProjectCustomField,
  type HubDetail,
  type HubProjectField,
  type HubProjectFieldInput,
  type HubProjectFieldOptionInput,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import type { ProjectAsk } from "../lib/project-workspace";
const kinds = ["text", "number", "date", "singleSelect"] as const;
export function ProjectFieldManager({
  detail,
  locked,
  ask,
}: {
  detail: HubDetail;
  locked: boolean;
  ask: ProjectAsk;
}) {
  const edit = useProjectEdit(ask);
  locked ||= edit.busy;
  const [editing, setEditing] = useState<HubProjectField | null | undefined>(
      undefined,
    ),
    [name, setName] = useState(""),
    [kind, setKind] = useState<HubProjectFieldInput["kind"]>("text"),
    [options, setOptions] = useState<HubProjectFieldOptionInput[]>([]);
  const beginEdit = (field: HubProjectField | null) => {
    setEditing(field);
    setName(field?.name ?? "");
    setKind((field?.kind as HubProjectFieldInput["kind"]) ?? "text");
    setOptions(
      field?.options.map((option) => ({
        id: option.id,
        name: option.name,
      })) ?? [{ name: "" }],
    );
  };
  const save = () => {
    const input: HubProjectFieldInput = {
      name,
      kind,
      ...(kind === "singleSelect" ? { options } : {}),
    };
    edit.run(
      editing ? t("Save project field changes?") : t("Create project field?"),
      `${name}\n${t(kind === "singleSelect" ? "Single select" : kind === "text" ? "Text" : kind === "number" ? "Number" : "Date")}${kind === "singleSelect" ? `\n${options.map((option) => option.name).join(", ")}` : ""}`,
      async (access) => {
        await saveHubProjectCustomField(
          access,
          detail,
          input,
          editing ?? undefined,
        );
        setEditing(undefined);
      },
    );
  };
  return (
    <div className="project-management-section">
      <div className="project-management-section-head">
        <div>
          <h3>{t("Project fields")}</h3>
          <p>{t("Define the information your team uses to plan work.")}</p>
        </div>
        <Button size="small" disabled={locked} onClick={() => beginEdit(null)}>
          <Plus size={13} />
          {t("New field")}
        </Button>
      </div>
      {edit.error && <p className="error-text" role="alert">{edit.error}</p>}
      {editing !== undefined && (
        <div className="project-management-editor">
          <div className="row">
            <label>
              {t("Field name")}
              <input
                className="input"
                value={name}
                disabled={locked}
                onChange={(event) => setName(event.target.value)}
              />
            </label>
            <label>
              {t("Field type")}
              <select
                className="select"
                value={kind}
                disabled={locked || !!editing}
                onChange={(event) =>
                  setKind(event.target.value as HubProjectFieldInput["kind"])
                }
              >
                {kinds.map((value) => (
                  <option value={value} key={value}>
                    {t(
                      value === "singleSelect"
                        ? "Single select"
                        : value === "number"
                          ? "Number"
                          : value === "date"
                            ? "Date"
                            : "Text",
                    )}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {kind === "singleSelect" && (
            <div className="project-option-editor">
              <span>{t("Options")}</span>
              {options.map((option, index) => (
                <div className="row" key={option.id ?? index}>
                  <input
                    className="input"
                    aria-label={t("Option name")}
                    value={option.name}
                    disabled={locked}
                    onChange={(event) =>
                      setOptions((current) =>
                        current.map((value, i) =>
                          i === index
                            ? { ...value, name: event.target.value }
                            : value,
                        ),
                      )
                    }
                  />
                  <Button
                    size="small"
                    tip={t("Remove option")}
                    aria-label={t("Remove option")}
                    disabled={locked}
                    onClick={() =>
                      setOptions((current) =>
                        current.filter((_, i) => i !== index),
                      )
                    }
                  >
                    <X size={13} />
                  </Button>
                </div>
              ))}
              <Button
                size="small"
                disabled={locked}
                onClick={() =>
                  setOptions((current) => [...current, { name: "" }])
                }
              >
                <Plus size={12} />
                {t("Add option")}
              </Button>
            </div>
          )}
          <div className="row">
            <Button
              kind="primary"
              size="small"
              disabled={
                locked ||
                !name.trim() ||
                (kind === "singleSelect" &&
                  (!options.length ||
                    options.some((option) => !option.name.trim()) ||
                    new Set(options.map((option) => option.name.trim()))
                      .size !== options.length))
              }
              onClick={save}
            >
              {t("Save field")}
            </Button>
            <Button
              size="small"
              disabled={locked}
              onClick={() => {
                ask.cancel?.();
                setEditing(undefined);
              }}
            >
              {t("Cancel")}
            </Button>
          </div>
        </div>
      )}
      <div className="project-field-catalog">
        {detail.fields.map((field) => (
          <div key={field.id}>
            <span>
              <strong>{field.name}</strong>
              <small>
                {t(
                  field.kind === "singleSelect" || !field.kind
                    ? "Single select"
                    : field.kind === "text"
                      ? "Text"
                      : field.kind === "number"
                        ? "Number"
                        : field.kind === "date"
                          ? "Date"
                          : field.kind === "iteration"
                            ? "Iteration"
                            : "Built-in field",
                )}
                {field.options.length
                  ? ` · ${t("{0} options", field.options.length)}`
                  : ""}
              </small>
            </span>
            {kinds.includes(field.kind as (typeof kinds)[number]) ? (
              <>
                <Button
                  size="small"
                  disabled={locked}
                  onClick={() => beginEdit(field)}
                >
                  {t("Edit")}
                </Button>
                <Button
                  size="small"
                  tip={t("Delete field")}
                  aria-label={t("Delete field")}
                  disabled={locked}
                  onClick={() =>
                    ask(
                      t("Delete this project field?"),
                      `${field.name}\n${t("This removes the field and its values from the project.")}`,
                      (access) =>
                        deleteHubProjectCustomField(access, detail, field),
                    )
                  }
                >
                  <Trash2 size={13} />
                </Button>
              </>
            ) : (
              <span className="hint">{t("Managed by GitHub")}</span>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
