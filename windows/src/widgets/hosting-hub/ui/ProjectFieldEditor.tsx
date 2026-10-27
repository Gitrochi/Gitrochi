import { useState } from "react";
import { Check } from "lucide-react";
import { parseScheduleDay, type HubProjectField, type HubProjectRow } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { projectFieldValue } from "../lib/project-workspace";
import { ProjectDateShortcuts } from "./ProjectDateShortcuts";

export function ProjectFieldEditor({
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
  save: (value: string | null) => Promise<boolean>;
}) {
  const localField = field.id.startsWith("local-");
  const original = projectFieldValue(row, field),
    [value, setValue] = useState(original);
  const selectable =
    field.kind === "singleSelect" ||
    field.kind === "iteration" ||
    (!field.kind && field.options.length > 0);
  const supported =
    selectable || ["text", "number", "date"].includes(field.kind ?? "");
  return (
    <label className={`project-field-editor ${field.kind === "date" ? "project-date-editor" : ""}`}>
      <span>{localField ? t(field.name) : field.name}</span>
      {selectable ? (
        <div className="project-field-input">
        <select
          className="select"
          disabled={locked}
          value={value}
          onChange={(event) => {
            setValue(event.target.value);
            void save(event.target.value || null);
          }}
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
        {value !== original && <Button size="small" tip={t("Save field")} aria-label={t("Save field")} disabled={locked} onClick={() => void save(value || null)}><Check size={13} /></Button>}
        </div>
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
            aria-label={t("Save field")}
            disabled={
              locked ||
              value === original ||
              (field.kind === "date" &&
                value !== "" &&
                !parseScheduleDay(value)) ||
              (field.kind === "number" &&
                value !== "" &&
                !Number.isFinite(Number(value)))
            }
            onClick={() => save(value || null)}
          >
            <Check size={13} />
          </Button>
          {field.kind === "date" && (
            <ProjectDateShortcuts choose={(date) => { setValue(date); void save(date); }} locked={locked} />
          )}
        </div>
      ) : (
        <span className="hint">
          {original || t("Manage this field in GitHub")}
        </span>
      )}
    </label>
  );
}
