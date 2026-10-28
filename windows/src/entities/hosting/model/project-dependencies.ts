import type { HubProjectRow } from "../api/hub";

export const projectDependencyLimits = { predecessors: 100, durationDays: 3650 } as const;
interface DependencyTask { id: string; predecessorIDs?: string[]; durationDays?: number }
export type ProjectDependencyError = "predecessors" | "cycle" | "duration";
export interface ProjectDependencyNode {
  row: HubProjectRow;
  level: number;
  completed: boolean;
  blockedBy: string[];
  critical: boolean;
}
export interface ProjectDependencyGraph {
  nodes: ProjectDependencyNode[];
  error?: ProjectDependencyError;
  durationDays?: number;
  missingDurations: number;
  archivedBlockers: number;
}

/** macOS: LocalProjectDependencies. Validate a whole project without recursive traversal. */
export function validateProjectDependencies(tasks: readonly DependencyTask[]): ProjectDependencyError | undefined {
  const ids = new Set(tasks.map((task) => task.id));
  if (ids.size !== tasks.length) return "predecessors";
  for (const task of tasks) {
    if (task.durationDays !== undefined && (!Number.isInteger(task.durationDays) || task.durationDays < 1 || task.durationDays > projectDependencyLimits.durationDays)) return "duration";
    if (task.predecessorIDs !== undefined && (!Array.isArray(task.predecessorIDs) || task.predecessorIDs.length > projectDependencyLimits.predecessors ||
      new Set(task.predecessorIDs).size !== task.predecessorIDs.length || task.predecessorIDs.some((id) => typeof id !== "string" || id === task.id || !ids.has(id)))) return "predecessors";
  }
  return dependencyOrder(tasks).length === tasks.length ? undefined : "cycle";
}

function dependencyOrder(tasks: readonly DependencyTask[]): DependencyTask[] {
  const remaining = new Map(tasks.map((task) => [task.id, task.predecessorIDs?.length ?? 0])),
    successors = new Map<string, DependencyTask[]>();
  for (const task of tasks) for (const id of task.predecessorIDs ?? []) {
    const list = successors.get(id) ?? [];
    list.push(task); successors.set(id, list);
  }
  const queue = tasks.filter((task) => !remaining.get(task.id));
  for (let index = 0; index < queue.length; index++) for (const task of successors.get(queue[index].id) ?? []) {
    const count = remaining.get(task.id)! - 1;
    remaining.set(task.id, count);
    if (count === 0) queue.push(task);
  }
  return queue;
}

/** Readiness uses real completion states; durations never change task dates or estimate capacity. */
export function projectDependencyGraph(rows: readonly HubProjectRow[]): ProjectDependencyGraph {
  const error = validateProjectDependencies(rows);
  if (error) return { nodes: [], error, missingDurations: 0, archivedBlockers: 0 };
  const byID = new Map(rows.map((row) => [row.id, row])),
    completed = (id: string) => byID.get(id)?.statuses["local-status"] === "local-done",
    levels = new Map<string, number>(),
    order = dependencyOrder(rows) as HubProjectRow[];
  const nodes = order.map((row): ProjectDependencyNode => {
    const predecessors = row.predecessorIDs ?? [],
      level = predecessors.length ? 1 + Math.max(...predecessors.map((id) => levels.get(id)!)) : 0;
    levels.set(row.id, level);
    return { row, level, completed: completed(row.id), blockedBy: predecessors.filter((id) => !completed(id)), critical: false };
  });
  const active = nodes.filter((node) => !node.completed && !node.row.archived),
    missingDurations = active.filter((node) => node.row.durationDays === undefined).length,
    archivedBlockers = active.filter((node) => node.blockedBy.some((id) => byID.get(id)?.archived)).length;
  if (!active.length || missingDurations || archivedBlockers) return { nodes, missingDurations, archivedBlockers };

  const earliest = new Map<string, number>(), latest = new Map<string, number>();
  let durationDays = 0;
  for (const node of nodes) {
    if (node.completed || node.row.archived) { earliest.set(node.row.id, 0); continue; }
    const start = Math.max(0, ...(node.row.predecessorIDs ?? []).map((id) => earliest.get(id)!)),
      finish = start + node.row.durationDays!;
    earliest.set(node.row.id, finish); durationDays = Math.max(durationDays, finish);
  }
  const activeIDs = new Set(active.map((node) => node.row.id));
  for (const node of active) latest.set(node.row.id, durationDays);
  for (const node of [...nodes].reverse()) {
    if (!activeIDs.has(node.row.id)) continue;
    const finish = latest.get(node.row.id)!, start = finish - node.row.durationDays!;
    node.critical = finish === earliest.get(node.row.id);
    for (const id of node.row.predecessorIDs ?? []) if (activeIDs.has(id)) latest.set(id, Math.min(latest.get(id)!, start));
  }
  return { nodes, durationDays, missingDurations, archivedBlockers };
}
