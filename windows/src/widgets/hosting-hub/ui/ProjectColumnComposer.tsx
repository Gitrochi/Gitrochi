import { useState } from "react";
import { Plus, X } from "lucide-react";
import { createHubProjectTask, type HubDetail, type HubProjectField } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
import type { ProjectAsk } from "../lib/project-workspace";
import { useProjectEdit } from "../model/use-project-edit";

/** A new task is created with its captured column, without an intermediate ungrouped task. */
export function ProjectColumnComposer({ detail, field, option, ask, locked, active, start, close }: {
  detail: HubDetail;
  field?: HubProjectField;
  option?: string;
  ask: ProjectAsk;
  locked: boolean;
  active: boolean;
  start: () => void;
  close: () => void;
}) {
  const [title, setTitle] = useState("");
  const edit = useProjectEdit(ask);
  const submit = async () => {
    if (locked || edit.busy || !title.trim()) return;
    const name = title.trim(), project = detail, group = field, column = option;
    if (await edit.run(t("Create task"), name,
      (access) => createHubProjectTask(access, project, name, "", group, column))) {
      setTitle("");
      close();
    }
  };
  return active ? (
    <form className="project-column-composer" aria-label={t("Add task to column")} onSubmit={(event) => { event.preventDefault(); void submit(); }}>
      <input className="input" autoFocus aria-label={t("Task title")} placeholder={t("Task title")}
        value={title} disabled={locked || edit.busy} onChange={(event) => setTitle(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Escape" && !edit.busy) { event.preventDefault(); close(); }
        }} />
      {edit.error && <p className="error-text" role="alert">{edit.error}</p>}
      <div>
        <Button kind="primary" size="small" type="submit" disabled={locked || edit.busy || !title.trim()}>
          {edit.busy ? <Spinner /> : <Plus size={13} />}{t("Create task")}
        </Button>
        <Button size="small" type="button" aria-label={t("Cancel")} tip={t("Cancel")} disabled={edit.busy} onClick={close}><X size={13} /></Button>
      </div>
    </form>
  ) : (
    <button className="project-column-add" disabled={locked} onClick={start}><Plus size={13} />{t("Add task")}</button>
  );
}
