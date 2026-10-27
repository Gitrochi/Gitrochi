import { CalendarDays, CheckCircle2, Plus, Settings2 } from "lucide-react";
import {
  resolveScheduleFields,
  type HubProjectField,
  type ProjectScheduleSettings,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";

export function ProjectScheduleControls({
  fields,
  settings,
  change,
  manageFields,
  locked,
  localProject = false,
}: {
  fields: HubProjectField[];
  settings: ProjectScheduleSettings;
  change: (value: ProjectScheduleSettings) => void;
  manageFields: () => void;
  locked: boolean;
  localProject?: boolean;
}) {
  const dates = fields.filter((field) => field.kind === "date"),
    selects = fields.filter(
      (field) =>
        field.kind === "singleSelect" || (!field.kind && field.options.length),
    ),
    resolved = resolveScheduleFields(fields, settings);
  return (
    <details className="project-schedule-config">
      <summary>
        <Settings2 size={14} />
        <strong>{t("Schedule setup")}</strong>
        <span>{resolved.due?.name ?? t("Choose a due date field")}</span>
        <span>
          {settings.completedOptionIDs.length
            ? t("Completion status configured")
            : t("Choose a completion status")}
        </span>
      </summary>
      <div className="project-schedule-config-body">
        <p>
          {t(
            localProject
              ? "Planning preferences and local task changes stay on this device."
              : "Choose the project fields used for planning. These view preferences stay on this device; task changes sync to GitHub.",
          )}
        </p>
        <div className="project-schedule-field-grid">
          <label>
            <span>
              <CalendarDays size={13} />
              {t("Start date field")}
            </span>
            <select
              className="select"
              disabled={locked}
              aria-label={t("Schedule start date field")}
              value={settings.startFieldID ?? "__auto"}
              onChange={(event) =>
                change({
                  ...settings,
                  startFieldID:
                    event.target.value === "__auto"
                      ? undefined
                      : event.target.value,
                })
              }
            >
              <option value="__auto">{t("Automatic")}</option>
              <option value="">{t("None")}</option>
              {dates.map((field) => (
                <option key={field.id} value={field.id}>
                  {field.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>
              <CalendarDays size={13} />
              {t("Due date field")}
            </span>
            <select
              className="select"
              disabled={locked}
              aria-label={t("Schedule due date field")}
              value={settings.dueFieldID ?? "__auto"}
              onChange={(event) =>
                change({
                  ...settings,
                  dueFieldID:
                    event.target.value === "__auto"
                      ? undefined
                      : event.target.value,
                })
              }
            >
              <option value="__auto">{t("Automatic")}</option>
              <option value="">{t("None")}</option>
              {dates.map((field) => (
                <option key={field.id} value={field.id}>
                  {field.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>
              <CheckCircle2 size={13} />
              {t("Completion field")}
            </span>
            <select
              className="select"
              disabled={locked}
              aria-label={t("Completion field")}
              value={settings.statusFieldID ?? "__auto"}
              onChange={(event) =>
                change({
                  ...settings,
                  statusFieldID:
                    event.target.value === "__auto"
                      ? undefined
                      : event.target.value,
                  completedOptionIDs: [],
                })
              }
            >
              <option value="__auto">{t("Automatic")}</option>
              <option value="">{t("None")}</option>
              {selects.map((field) => (
                <option key={field.id} value={field.id}>
                  {field.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>
              <CheckCircle2 size={13} />
              {t("Complete tasks with")}
            </span>
            <select
              className="select"
              aria-label={t("Complete tasks with")}
              value={settings.completedOptionIDs[0] ?? ""}
              disabled={locked || !resolved.status}
              onChange={(event) =>
                change({
                  ...settings,
                  completedOptionIDs: event.target.value
                    ? [event.target.value]
                    : [],
                })
              }
            >
              <option value="">{t("Choose a completion status")}</option>
              {resolved.status?.options.map((option) => (
                <option key={option.id} value={option.id}>
                  {option.name}
                </option>
              ))}
            </select>
          </label>
        </div>
        <div className="project-schedule-setup-note">
          <span>
            {t(
              localProject
                ? "Completed local tasks are counted using their saved status."
                : "Closed issues and merged pull requests are also counted as completed. Column position never determines completion.",
            )}
          </span>
          {!localProject && (
            <Button size="small" disabled={locked} onClick={manageFields}>
              <Plus size={13} />
              {t("Manage date fields")}
            </Button>
          )}
        </div>
      </div>
    </details>
  );
}
