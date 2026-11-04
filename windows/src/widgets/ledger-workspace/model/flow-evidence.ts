import { flowEngine } from "@/entities/flow";
import type { Worktree } from "@/entities/git";
import { Observable } from "@/shared/lib";
import { git } from "@/shared/platform";
import { latestFlowResults, type LedgerFlowResult, type LedgerFlowRun } from "../lib/flow-evidence";

/** What the Ledger uses of the repository's tab for the Checks row: its folder and worktrees, and its page navigation. The repository store satisfies it as it is. */
export interface LedgerFlowHost {
  readonly path: string | null;
  readonly worktrees: readonly Worktree[];
  navigate(page: "flows"): unknown;
}

/** What the row shows for one branch in one repository */
export interface LedgerFlowEvidence { head: string; results: LedgerFlowResult[] }

/** How many of each folder's newest runs are looked at: the Flows history lists at most 50 */
export const FLOW_RUNS_READ = 20;

/**
 * The Checks row's evidence: Flow results recorded for a session's branch head, read the way the Flows workspace reads
 * them (`flowEngine.runs`, `flowEngine.record`, which only read run records) and `git rev-parse` for the head. It never
 * starts a run or touches flow files, trust or records. Finished records never change, so each is read once.
 * (macOS: Store/LedgerFlowEvidenceStore.swift)
 */
export class LedgerFlowEvidenceStore extends Observable {
  private evidence = new Map<string, LedgerFlowEvidence>();
  private records = new Map<string, LedgerFlowRun>();
  private reading = new Set<string>();

  static key = (repo: string, branch: string) => `${repo}\0${branch}`;

  get(repo: string, branch: string): LedgerFlowEvidence | null {
    return this.evidence.get(LedgerFlowEvidenceStore.key(repo, branch)) ?? null;
  }

  /** Reads the branch's head and the newest run records of each folder; without the engine or the branch, nothing */
  async refresh(repo: string, branch: string, folders: readonly string[]): Promise<void> {
    const key = LedgerFlowEvidenceStore.key(repo, branch);
    if (this.reading.has(key)) return;
    this.reading.add(key);
    try {
      const head = branch && (await flowEngine.executable())
        ? (await git(["rev-parse", "--verify", "--quiet", `refs/heads/${branch}^{commit}`], repo, { ok: [0, 1, 128] }).catch(() => null))?.stdout.trim() ?? ""
        : "";
      if (!head) return this.set(key, null);
      const runs: LedgerFlowRun[] = [];
      for (const folder of folders) {
        const rows = await flowEngine.runs(folder).catch(() => []);
        for (const row of rows.slice(0, FLOW_RUNS_READ)) {
          if (row.running) continue;
          const id = `${folder}\0${row.runId}`;
          const known = this.records.get(id);
          if (known) { runs.push(known); continue; }
          const record = await flowEngine.record(row.runId, folder).catch(() => null);
          if (!record) continue;
          const finished = typeof record.finishedAt === "string" ? Date.parse(record.finishedAt) : NaN;
          const sha = (record.git as { sha?: unknown } | undefined)?.sha;
          const run: LedgerFlowRun = { runId: row.runId, flow: typeof record.flow === "string" ? record.flow : row.flow, state: typeof record.state === "string" ? record.state : row.state, sha: typeof sha === "string" ? sha : "", finishedAt: Number.isFinite(finished) ? finished : null };
          if (run.finishedAt != null) this.records.set(id, run);
          runs.push(run);
        }
      }
      this.set(key, { head, results: latestFlowResults(runs, head) });
    } finally {
      this.reading.delete(key);
    }
  }

  private set(key: string, next: LedgerFlowEvidence | null) {
    const old = this.evidence.get(key) ?? null;
    if (JSON.stringify(old) === JSON.stringify(next)) return;
    if (next) this.evidence.set(key, next); else this.evidence.delete(key);
    this.emit();
  }
}

/** The app's one cache */
export const ledgerFlowEvidence = new LedgerFlowEvidenceStore();
