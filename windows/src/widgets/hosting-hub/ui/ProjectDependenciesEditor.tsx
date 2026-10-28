import { useEffect, useState } from "react";
import { projectDependencyGraph, saveHubProjectDependencies, type HubDetail, type HubProjectRow } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import type { ProjectAsk } from "../lib/project-workspace";
import { useProjectEdit } from "../model/use-project-edit";
import "./project-dependencies.css";

/** Local predecessors and explicit durations save together without moving any dates. */
export function ProjectDependenciesEditor({ detail, row, locked, ask }: {
  detail: HubDetail; row: HubProjectRow; locked: boolean; ask: ProjectAsk;
}) {
  const [selected, setSelected] = useState(() => new Set(row.predecessorIDs ?? [])),
    [duration, setDuration] = useState(row.durationDays?.toString() ?? ""),
    [query, setQuery] = useState("");
  const edit = useProjectEdit(ask),
    predecessorKey = JSON.stringify(row.predecessorIDs ?? []);
  useEffect(() => { setSelected(new Set(JSON.parse(predecessorKey) as string[])); setDuration(row.durationDays?.toString() ?? ""); }, [row.id, predecessorKey, row.durationDays]);
  const validDuration = duration === "" || /^\d+$/.test(duration) && Number(duration) >= 1 && Number(duration) <= 3650,
    candidates = detail.rows.filter((candidate) => candidate.id !== row.id && (!query.trim() || candidate.title.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))),
    graph = projectDependencyGraph(detail.rows), node = graph.nodes.find((value) => value.row.id === row.id),
    dirty = duration !== (row.durationDays?.toString() ?? "") || JSON.stringify([...selected].sort()) !== JSON.stringify([...(row.predecessorIDs ?? [])].sort());
  return <section className="project-dependencies-editor" aria-label={t("Task predecessors")}>
    <h3>{t("Task predecessors")}</h3>
    <p className="hint">{t("A task is ready when its predecessors are done. Archived unfinished predecessors keep it blocked.")}</p>
    {node && <p className="project-dependency-state">{t(node.completed ? "Done" : row.archived ? "Archived" : node.blockedBy.length ? "Blocked" : "Ready")}</p>}
    <fieldset disabled={locked || row.archived || edit.busy}>
      <label>{t("Find predecessor tasks")}<input className="input" aria-label={t("Find predecessor tasks")} value={query} onChange={(event) => setQuery(event.target.value)} /></label>
      <div className="project-predecessor-choices">
        {candidates.slice(0, 60).map((candidate) => <label key={candidate.id}>
          <input type="checkbox" checked={selected.has(candidate.id)} onChange={(event) => setSelected((current) => {
            const next = new Set(current);
            if (event.target.checked) next.add(candidate.id); else next.delete(candidate.id);
            return next;
          })} />
          <span>{candidate.title}{candidate.archived ? ` · ${t("Archived")}` : ""}</span>
        </label>)}
        {!candidates.length && <p className="hint">{t("No other matching tasks in this project.")}</p>}
      </div>
      {candidates.length > 60 && <p className="hint">{t("Showing {0} of {1} tasks. Refine the search to find more.", 60, candidates.length)}</p>}
      <p className="hint">{t("{0} predecessors selected", selected.size)}</p>
      {selected.size > 100 && <p className="error-text" role="alert">{t("Choose up to 100 different predecessor tasks from this project, excluding this task.")}</p>}
      <label>{t("Duration (days)")}<input className="input" type="number" min={1} max={3650} step={1} aria-label={t("Duration (days)")} value={duration} onChange={(event) => setDuration(event.target.value)} /></label>
      {!validDuration && <p className="error-text" role="alert">{t("Enter a duration from 1 to 3650 whole days, or leave it empty.")}</p>}
      <p className="hint">{t("Durations are explicit estimates. Saving predecessors never reschedules tasks.")}</p>
      <Button size="small" kind="primary" disabled={!dirty || !validDuration || selected.size > 100} onClick={() => void edit.run(t("Save task dependencies"), row.title,
        (access) => saveHubProjectDependencies(access, detail, row, [...selected], duration === "" ? undefined : Number(duration)))}>{t(edit.busy ? "Saving…" : "Save task dependencies")}</Button>
    </fieldset>
    {edit.error && <p className="error-text" role="alert">{edit.error}</p>}
    <p className="hint">{t("Clear predecessor links from dependent tasks before deleting their predecessor.")}</p>
  </section>;
}
