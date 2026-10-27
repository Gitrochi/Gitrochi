import { useEffect, useState } from "react";
import {
  localScheduleToday,
  resolveScheduleFields,
  updateHubProjectField,
  scheduleReschedule,
  rescheduleHubProjectItem,
  readProjectScheduleSettings,
  saveProjectScheduleSettings,
  type HubDetail,
  type HubProjectRow,
  type ProjectScheduleSettings,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import type { ProjectAsk } from "../lib/project-workspace";
import { useProjectEdit } from "./use-project-edit";

/** Local view choices contain field identifiers only; task dates are written to the server. */
export function useProjectSchedule(
  detail: HubDetail,
  context: string,
  ask: ProjectAsk,
) {
  const edit = useProjectEdit(ask);
  const key = `${context}:${detail.item.id}`;
  const [saved, setSaved] = useState(() => ({
    key,
    value: readProjectScheduleSettings(context, detail.item.id),
  }));
  const settings =
    saved.key === key
      ? saved.value
      : readProjectScheduleSettings(context, detail.item.id);
  const [today, setToday] = useState(localScheduleToday);
  useEffect(() => {
    const refresh = () =>
      setSaved({
        key,
        value: readProjectScheduleSettings(context, detail.item.id),
      });
    window.addEventListener("gitrochi-project-schedule-settings", refresh);
    window.addEventListener("storage", refresh);
    return () => {
      window.removeEventListener("gitrochi-project-schedule-settings", refresh);
      window.removeEventListener("storage", refresh);
    };
  }, [key, context, detail.item.id]);
  useEffect(() => {
    const refresh = () => setToday(localScheduleToday());
    const timer = setInterval(refresh, 60_000);
    window.addEventListener("focus", refresh);
    return () => {
      clearInterval(timer);
      window.removeEventListener("focus", refresh);
    };
  }, []);
  const changeSettings = (value: ProjectScheduleSettings) => {
    ask.cancel?.();
    setSaved({ key, value });
    saveProjectScheduleSettings(context, detail.item.id, value);
  };
  const reschedule = (row: HubProjectRow, date: string) => {
    const changes = scheduleReschedule(row, detail.fields, settings, date);
    if (!changes.length) return;
    const description = changes
      .map(
        (change) =>
          `${detail.fields.find((field) => field.id === change.fieldID)?.name ?? ""}: ${change.value}`,
      )
      .join("\n");
    ask(
      t("Reschedule this task?"),
      `${row.title}\n\n${description}\n\n${t(detail.item.data.localProject === true ? "Dates are saved on this device. The task duration is preserved when both dates are set." : "Dates are saved to the connected project. The task duration is preserved when both dates are set.")}`,
      (access) => rescheduleHubProjectItem(access, detail, row, settings, date),
    );
  };
  const assignDate = async (row: HubProjectRow, date: string) => {
    scheduleReschedule(row, detail.fields, settings, date);
    return edit.run(t("Schedule task"), row.title,
      (access) => rescheduleHubProjectItem(access, detail, row, settings, date));
  };
  const complete = (row: HubProjectRow, locked: boolean) => {
    const status = resolveScheduleFields(detail.fields, settings).status,
      option = status?.options.find((value) =>
        settings.completedOptionIDs.includes(value.id),
      );
    if (locked || !status || !option) return;
    void edit.run(
      t("Complete this task?"),
      `${row.title}\n${status.name}: ${option.name}\n\n${t("This updates the project status. It does not close the linked issue or pull request.")}`,
      (access) => updateHubProjectField(access, detail, row, status, option.id),
    );
  };
  return { settings, changeSettings, today, reschedule, assignDate, complete, busy: edit.busy, error: edit.error };
}
