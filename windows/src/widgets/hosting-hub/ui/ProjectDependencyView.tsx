import { useState } from "react";
import { ArrowRight } from "lucide-react";
import { projectDependencyGraph, type HubProjectRow, type ProjectDependencyNode } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import "./project-dependencies.css";

/** A focused DAG neighborhood keeps every relationship readable without a sprawling canvas. */
export function ProjectDependencyView({ rows, select, selectedID }: { rows: HubProjectRow[]; select: (row: HubProjectRow) => void; selectedID?: string | null }) {
  const [focusID, setFocusID] = useState(""), [query, setQuery] = useState("");
  const graph = projectDependencyGraph(rows),
    matches = graph.nodes.filter((node) => !query.trim() || node.row.title.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())),
    focus = graph.nodes.find((node) => node.row.id === (selectedID ?? focusID)) ?? matches[0],
    predecessors = graph.nodes.filter((node) => focus?.row.predecessorIDs?.includes(node.row.id)),
    successors = graph.nodes.filter((node) => node.row.predecessorIDs?.includes(focus?.row.id ?? ""));
  const pick = (node: ProjectDependencyNode) => { setFocusID(node.row.id); select(node.row); },
    state = (node: ProjectDependencyNode) => t(node.completed ? "Done" : node.row.archived ? "Archived" : node.blockedBy.length ? "Blocked" : "Ready"),
    task = (node: ProjectDependencyNode) => <button type="button" className={`project-dependency-node ${node.critical ? "critical" : ""}`} key={node.row.id} onClick={() => pick(node)} aria-pressed={focus?.row.id === node.row.id}>
      <strong>{node.row.title}</strong><span>{state(node)}{node.critical ? ` · ${t("Critical path")}` : ""}</span>
      {node.row.durationDays !== undefined && <span>{t("{0} days", node.row.durationDays)}</span>}
    </button>;
  return <section className="project-dependency-view" aria-label={t("Task dependency graph")}>
    <header><h3>{t("Task dependency graph")}</h3><span>{t("{0} ready · {1} blocked", graph.nodes.filter((node) => !node.completed && !node.row.archived && !node.blockedBy.length).length, graph.nodes.filter((node) => !node.completed && !node.row.archived && !!node.blockedBy.length).length)}</span></header>
    <p className="hint">{t("All local tasks are included. Roadmap filters do not hide predecessor links.")}</p>
    {graph.error ? <p className="error-text" role="alert">{t("Task dependencies are invalid. Saved data has not been changed.")}</p> : <>
      {graph.durationDays !== undefined ? <p className="project-dependency-state">{t("Critical path: {0} days", graph.durationDays)}</p> : <p className="hint">{t("A critical path needs an explicit duration for every active task and no unfinished archived predecessor.")}</p>}
      <p className="hint">{t("Critical paths use stated durations and completion states, without calendar or capacity estimates. Task dates stay unchanged.")}</p>
      <label>{t("Find a task in the graph")}<input className="input" aria-label={t("Find a task in the graph")} value={query} onChange={(event) => { setQuery(event.target.value); setFocusID(""); }} /></label>
      <div className="project-dependency-task-picker">{matches.slice(0, 40).map(task)}</div>
      {matches.length > 40 && <p className="hint">{t("Showing {0} of {1} tasks. Refine the search to find more.", 40, matches.length)}</p>}
      {focus && <div className="project-dependency-neighborhood" role="group" aria-label={t("Selected task relationships")}>
        <div><h4>{t("Predecessors")}</h4>{predecessors.map(task)}{!predecessors.length && <p className="hint">{t("None")}</p>}</div>
        <ArrowRight className="project-dependency-arrow" size={18} aria-label={t("Precedes")} />
        <div><h4>{t("Selected task")}</h4>{task(focus)}</div>
        <ArrowRight className="project-dependency-arrow" size={18} aria-label={t("Precedes")} />
        <div><h4>{t("Successors")}</h4>{successors.slice(0, 60).map(task)}{!successors.length && <p className="hint">{t("None")}</p>}{successors.length > 60 && <p className="hint">{t("Showing {0} of {1} tasks. Refine the search to find more.", 60, successors.length)}</p>}</div>
      </div>}
      {!matches.length && <p className="hint">{t("No matching tasks")}</p>}
    </>}
  </section>;
}
