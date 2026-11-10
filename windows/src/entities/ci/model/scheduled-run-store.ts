import { accountApiBase } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import { samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { describe } from "@/shared/platform";
import { CIAPI } from "../api/ci-api";
import { decodeScheduledRuns, type ScheduledRun, scheduledRunAction, scheduledRunsFor, scheduleInterval } from "./scheduled-runs";

/** Where the runs are kept, what time it is and how a run starts; the self-test brings its own */
export interface ScheduledRunHost {
  now(): number;
  read(): ScheduledRun[];
  write(runs: ScheduledRun[]): void;
  start(run: ScheduledRun): Promise<void>;
}

/** The same calls as the run sheet, with the saved account's token read now */
async function dispatch(run: ScheduledRun) {
  const account = accounts.accounts.find((a) => a.id === run.accountID);
  if (!account) throw new Error(t("The account for this run is no longer connected."));
  const token = await accounts.token(account, { reportReadFailure: true });
  if (!token) throw new Error(t("Couldn't read the account's token."));
  const c = { target: { provider: run.provider, host: run.host, remote: run.remote, path: run.path }, token, apiBase: accountApiBase(account) };
  if (run.provider === "gitlab") await CIAPI.runPipeline(c, run.ref, run.variables);
  else if (run.workflowID !== null) await CIAPI.dispatch(c, run.workflowID, run.ref, run.inputs);
  else throw new Error(t("This branch has no workflow with 'Run workflow' (workflow_dispatch)."));
}

const appHost: ScheduledRunHost = {
  now: () => Date.now(),
  read: () => decodeScheduledRuns(settings.get<unknown>("scheduledRuns", [])),
  write: (runs) => settings.set("scheduledRuns", runs),
  start: dispatch,
};

/**
 * Every repository's runs scheduled for later, and the clock that starts them while the app is open: at launch, after
 * sleep and every 30 seconds, whether or not the repository is open. Kept in the settings, without tokens.
 * (macOS: Services/ScheduledRunStore.swift)
 */
export class ScheduledRunStore extends Observable {
  /** Runs being started now, so a check meanwhile does not start one twice */
  readonly starting = new Set<string>();
  /** A run started: the app shows it in its repository, if that is open */
  onStarted: ((run: ScheduledRun) => void) | null = null;
  private host: ScheduledRunHost = appHost;

  /** Swaps in another clock, store and start (the self-test's); returns the one it replaced */
  useHost(host: ScheduledRunHost): ScheduledRunHost {
    const previous = this.host;
    this.host = host;
    this.emit();
    return previous;
  }

  now() {
    return this.host.now();
  }

  get runs(): ScheduledRun[] {
    return this.host.read();
  }

  /** The repository's runs, soonest first */
  forRepo(repoPath: string | null) {
    return scheduledRunsFor(this.runs, repoPath, samePath);
  }

  add(run: ScheduledRun) {
    this.write([...this.runs, run]);
  }

  remove(id: string) {
    this.write(this.runs.filter((run) => run.id !== id));
  }

  /** Run now on a missed or failed run: starts it at once */
  runNow(id: string): Promise<void> {
    const run = this.runs.find((r) => r.id === id);
    return run ? this.begin(run) : Promise.resolve();
  }

  /** Starts the runs that are due and marks the ones found too late as missed; resolves once the starts have settled */
  async check(): Promise<void> {
    const now = this.host.now(), starts: Promise<void>[] = [];
    for (const run of this.runs) {
      if (this.starting.has(run.id)) continue;
      const action = scheduledRunAction(run, now);
      if (action === "start") starts.push(this.begin(run));
      else if (action === "miss") this.update(run.id, { state: "missed", message: null });
    }
    await Promise.all(starts);
  }

  /**
   * Checks now, every 30 seconds and when the window comes back. Timers stand still while the computer sleeps, so the
   * first check after waking finds what came due meanwhile. Returns the stop.
   */
  start(): () => void {
    void this.check();
    const timer = setInterval(() => void this.check(), scheduleInterval);
    const back = () => { if (document.visibilityState === "visible") void this.check(); };
    document.addEventListener("visibilitychange", back);
    window.addEventListener("focus", back);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", back);
      window.removeEventListener("focus", back);
    };
  }

  private async begin(run: ScheduledRun) {
    if (this.starting.has(run.id)) return;
    this.starting.add(run.id);
    this.emit();
    try {
      await this.host.start(run);
      this.starting.delete(run.id);
      this.remove(run.id);
      this.onStarted?.(run);
    } catch (e) {
      this.starting.delete(run.id);
      this.update(run.id, { state: "failed", message: describe(e) });
    }
  }

  private update(id: string, patch: Partial<ScheduledRun>) {
    this.write(this.runs.map((run) => (run.id === id ? { ...run, ...patch } : run)));
  }

  private write(runs: ScheduledRun[]) {
    this.host.write(runs);
    this.emit();
  }
}

export const scheduledRuns = new ScheduledRunStore();
