import { createRoot } from "react-dom/client";
import { flowEngine, type FlowRunRow } from "@/entities/flow";
import { DemoLedgerBackend, LedgerStore } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { LedgerWorkspace } from "@/widgets/ledger-workspace";

const pause = (ms = 40) => new Promise<void>((resolve) => setTimeout(resolve, ms));
async function until(f: () => unknown, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (f()) return true;
    await pause(30);
  }
  return !!f();
}

/**
 * The inspector's Checks row on the demo backend, with fixture Flow run records behind the engine calls the Flows
 * workspace uses: the latest result of each flow for the branch head only, Open in Flows navigating, nothing for a
 * branch without runs on its head or without a repository, and nothing started, written or trusted.
 */
export async function ledgerFlowSelfTest(): Promise<[boolean, string]> {
  const original = { run: ipc.run };
  const engine = flowEngine as unknown as Record<string, unknown>;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:1400px;height:900px";
  document.body.append(host);
  let root = createRoot(host);
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const head = "c0ffee0000000000000000000000000000000142", calls: string[] = [], navigated: string[] = [];
  try {
    // git answers the branch heads; anything else would be a process the row must not start
    ipc.run = async (program, args) => {
      const ref = args.find((a) => a.startsWith("refs/heads/"));
      calls.push(ref ? `git rev-parse ${ref}` : `${program} ${args.join(" ")}`);
      if (ref === "refs/heads/fix/sign-in-retry^{commit}") return { status: 0, stdout: `${head}\n`, stderr: "" };
      if (ref) return { status: 0, stdout: "0123456789abcdef0123456789abcdef01234567\n", stderr: "" };
      throw new Error("Ledger Checks fixture blocked a process");
    };
    const rows: FlowRunRow[] = [
      { runId: "r4", flow: "nightly", state: "RUNNING", running: true },
      { runId: "r3", flow: "pre-push", state: "SUCCEEDED" },
      { runId: "r2", flow: "deploy", state: "ROLLBACK_FAILED" },
      { runId: "r1", flow: "pre-push", state: "FAILED" },
      { runId: "r0", flow: "lint", state: "SUCCEEDED" },
    ];
    const records: Record<string, Record<string, unknown>> = {
      r3: { runId: "r3", flow: "pre-push", state: "SUCCEEDED", finishedAt: "2026-10-31T08:30:00.000Z", git: { sha: head } },
      r2: { runId: "r2", flow: "deploy", state: "ROLLBACK_FAILED", finishedAt: "2026-10-31T08:00:00.000Z", git: { sha: head } },
      r1: { runId: "r1", flow: "pre-push", state: "FAILED", finishedAt: "2026-10-31T07:00:00.000Z", git: { sha: head } },
      r0: { runId: "r0", flow: "lint", state: "SUCCEEDED", finishedAt: "2026-10-31T06:00:00.000Z", git: { sha: "f00d" } },
    };
    engine.executable = async () => "/fixture/gitch-flow";
    engine.runs = async (repo: string) => { calls.push(`flow status --all ${repo}`); return rows; };
    engine.record = async (id: string) => { calls.push(`flow status ${id}`); return records[id]; };
    for (const name of ["start", "trust", "cancel", "setGate", "writeInit"]) engine[name] = async () => { calls.push(`flow ${name}`); throw new Error("Ledger Checks fixture blocked a flow change"); };

    const clock = Date.UTC(2026, 9, 31, 9);
    const store = new LedgerStore(new DemoLedgerBackend({ now: () => clock, repoPath: "C:/fixture/atlas" }));
    await store.refresh(true);
    const session = (title: string) => store.state!.sessions.find((s) => s.title === title)!;
    const retry = session("Retry policy for the sign-in service"), apiRef = session("Export the API reference");
    ensure(retry?.links.branch === "fix/sign-in-retry" && apiRef?.links.branch, "The demo sessions must carry branches");

    // Without a repository's tab there is no Checks row and nothing is read
    root.render(<LedgerWorkspace repoPath="C:/fixture/atlas" ledger={store} />);
    store.select(retry.id);
    ensure(await until(() => $(".ledger-inspector h2")?.textContent === retry.title), "The inspector did not open");
    await pause(200);
    ensure(!$(".ledger-flow-checks") && !calls.length, "Without a repository the Ledger must not read Flow records");
    root.unmount();
    root = createRoot(host);

    const flows = { path: "C:/fixture/atlas", worktrees: [], navigate: (page: "flows") => { navigated.push(page); } };
    root.render(<LedgerWorkspace repoPath="C:/fixture/atlas" ledger={store} flows={flows} />);
    store.select(retry.id);
    ensure(await until(() => $(".ledger-flow-checks [data-flow-outcome='held']")), "The Checks row did not show the branch head's results");
    const outcomes = [...host.querySelectorAll<HTMLElement>(".ledger-flow-checks .ledger-flow-result")].map((row) => `${row.dataset.flowOutcome}:${row.querySelector(".ledger-row-text")?.textContent}`);
    ensure(JSON.stringify(outcomes) === JSON.stringify(["passed:pre-push", "held:deploy"]), `Only the newest result of each flow for the head must show: ${outcomes.join(", ")}`);
    ensure($(".ledger-flow-checks .status-pill")?.textContent === t("Passed") && $(".ledger-flow-checks .mono")?.textContent === head.slice(0, 8), "The row must name the outcome and the head commit");
    $<HTMLButtonElement>(".ledger-flow-checks [data-open-flows]")!.click();
    ensure(navigated.join() === "flows", "Open in Flows did not go to the Flows workspace");

    // A branch whose head has no recorded run shows no row
    store.select(apiRef.id);
    ensure(await until(() => $(".ledger-inspector h2")?.textContent === apiRef.title), "The inspector did not switch sessions");
    await pause(300);
    ensure(!$(".ledger-flow-checks"), "A branch head without runs must not show the Checks row");

    const changes = calls.filter((c) => !c.startsWith("git rev-parse") && !c.startsWith("flow status"));
    ensure(!changes.length, `The Checks row may only read: ${changes.join(", ")}`);
    ensure(!calls.includes("flow status r4"), "A running run is not a recorded result");
    return [true, `latest result per flow for the branch head, Open in Flows, hidden without runs or a repository; ${calls.length} reads`];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally {
    ipc.run = original.run;
    for (const name of ["executable", "runs", "record", "start", "trust", "cancel", "setGate", "writeInit"]) delete engine[name];
    root.unmount();
    host.remove();
  }
}
