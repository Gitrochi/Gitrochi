/** Revision-bound evidence, mirrored by macOS WorkValidation.swift. */
export interface ValidationBinding {
  schemaVersion: 1;
  runID: string;
  head: string | null;
  before: string;
  after?: string;
  candidates: string[];
  observedAt: string;
}

export interface FlowEvidence {
  runID: string;
  state: string;
  freshness: "current" | "stale" | "unbound" | "running";
  executed: number | null;
  passed: number | null;
  failed: number | null;
}

const object = (value: unknown): Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const count = (value: unknown): number | null => Number.isSafeInteger(value) && Number(value) >= 0 ? Number(value) : null;

/** A successful flow does not imply a test count or candidate coverage. */
export function flowEvidence(record: unknown, binding: ValidationBinding | undefined, currentStamp: string): FlowEvidence {
  const run = object(record);
  const running = ["PENDING", "PREFLIGHT", "RUNNING", "ROLLING_BACK"].includes(String(run.state));
  const runID = String(run.runId ?? "");
  const terminal = ["SUCCEEDED", "FAILED", "REJECTED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED"].includes(String(run.state)) && typeof run.finishedAt === "string" && Number.isFinite(Date.parse(run.finishedAt));
  const bound = binding?.schemaVersion === 1 && binding.runID === runID;
  const git = object(run.git);
  const same = bound && terminal && !/^(?:untracked|uncertified):/.test(binding.before) && binding.head === git.sha && binding.before === binding.after && binding.after === currentStamp;
  const tests = (Array.isArray(run.nodes) ? run.nodes : []).map(node => object(object(node).tests)).filter(node => count(node.executed) !== null);
  const total = (key: string) => { const value = tests.length && tests.every(node => count(node[key]) !== null) ? tests.reduce((sum, node) => sum + Number(node[key]), 0) : null; return value !== null && Number.isSafeInteger(value) ? value : null; };
  return { runID, state: String(run.state ?? "UNKNOWN"), freshness: running ? "running" : !bound || !binding.after || !terminal ? "unbound" : same ? "current" : "stale", executed: total("executed"), passed: total("passed"), failed: total("failed") };
}

/** Relative paths never become commands or absolute machine paths. */
export function safeWorkPath(path: string): boolean {
  return !!path && path.length <= 1024 && !/[\x00-\x1f\\:]/.test(path) && !path.startsWith("/") && path.split("/").every(part => !!part && part !== "." && part !== "..");
}

/** Explicit task ownership is distinct from inferred file authorship. */
export interface AgentAssignment { sessionID: string; taskID: string; goal: string; paths: string[]; remaining: string; }

export function decodeAgentAssignments(raw: unknown): AgentAssignment[] {
  if (!Array.isArray(raw)) return [];
  return raw.slice(0, 200).flatMap(value => {
    const item = object(value);
    if (typeof item.sessionID !== "string" || typeof item.taskID !== "string" || typeof item.goal !== "string" || typeof item.remaining !== "string" || !Array.isArray(item.paths) || !item.paths.every(path => typeof path === "string" && safeWorkPath(path))) return [];
    return [{ sessionID: item.sessionID.slice(0, 200), taskID: item.taskID.slice(0, 200), goal: item.goal.slice(0, 2000), remaining: item.remaining.slice(0, 4000), paths: [...new Set(item.paths as string[])].slice(0, 100) }];
  });
}

export function decodeValidationBindings(raw: unknown): ValidationBinding[] {
  if (!Array.isArray(raw)) return [];
  return raw.slice(-100).flatMap(value => {
    const row = object(value);
    if (row.schemaVersion !== 1 || typeof row.runID !== "string" || (row.head !== null && typeof row.head !== "string") || typeof row.before !== "string" || typeof row.observedAt !== "string" || (row.after !== undefined && typeof row.after !== "string") || !Array.isArray(row.candidates) || !row.candidates.every(path => typeof path === "string" && safeWorkPath(path))) return [];
    return [row as unknown as ValidationBinding];
  });
}

export function taskBoundaryOverlaps(assignments: AgentAssignment[]): { a: string; b: string; paths: string[] }[] {
  const result: { a: string; b: string; paths: string[] }[] = [];
  assignments.forEach((a, index) => assignments.slice(index + 1).forEach(b => {
    const paths = [...new Set(a.paths.flatMap(left => b.paths.filter(right => left === right || left.startsWith(right + "/") || right.startsWith(left + "/")).map(right => left.length >= right.length ? left : right)))];
    if (paths.length) result.push({ a: a.sessionID, b: b.sessionID, paths });
  }));
  return result;
}

/** Export only deliberate task content and repository-relative evidence. */
export function handoffReport(input: { head: string | null; stamp: string; appVersion?: string; changedPaths?: string[]; candidates: string[]; evidence: FlowEvidence[]; assignments: AgentAssignment[]; sessions?: { taskID: string; kind: string; state: string; branch: string | null; observedAt: string }[]; observedAt: string }): string {
  const report = { schemaVersion: 1, kind: "gitrochi-work-handoff", tool: { name: "Gitrochi", version: input.appVersion ?? "unknown" }, revision: input.head, scope: "tracked-worktree", contentStamp: input.stamp, observedAt: input.observedAt, changedPaths: input.changedPaths?.filter(safeWorkPath) ?? [], candidates: input.candidates.filter(safeWorkPath), verification: input.evidence, assignments: input.assignments.map(({ sessionID, ...task }) => ({ ...task, paths: task.paths.filter(safeWorkPath) })), sessions: input.sessions ?? [], limitations: ["Candidates are not proof of test execution or coverage.", "An unchanged before/after stamp does not freeze the repository during a run.", "Untracked file contents are excluded; untracked changes prevent a verified current result."] };
  const scrub = (value: unknown): unknown => {
    if (typeof value === "string") return value.replace(/(?:[A-Za-z]:[\\/]|\/(?:Users|home)\/)[^\s"<>]+/g, "[local path]").replace(/\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|glpat-[A-Za-z0-9_-]{12,}|grh_[A-Za-z0-9_-]{12,}|sk-[A-Za-z0-9_-]{16,})\b/g, "[redacted]");
    if (Array.isArray(value)) return value.map(scrub);
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, scrub(item)]));
    return value;
  };
  return JSON.stringify(scrub(report), null, 2);
}
