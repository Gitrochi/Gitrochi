import { createRoot } from "react-dom/client";
import { agents, type AgentSession } from "@/entities/agent";
import { flowStoreFor } from "@/entities/flow";
import { RepoStore } from "@/entities/repo";
import { WorkValidationSheet } from "@/features/work-validation";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { worktreeStamp } from "@/shared/platform";

/** Memory-only production-panel fixture; no user settings, processes, credentials or hub are accessed. */
export async function workValidationFixture() {
  const path = `C:/work-validation-fixture-${crypto.randomUUID()}`, head = "a".repeat(40),
    store = new RepoStore(), values = new Map<string, unknown>(),
    secret = "grh_" + "x".repeat(24);
  const original = { run: ipc.run, hubRead: ipc.hubRead, http: ipc.http, secretGet: ipc.secretGet, secretSet: ipc.secretSet, get: settings.get, set: settings.set, sessions: agents.sessions };
  let diff = "", hubMode: "empty" | "overlap" | "error" = "empty", hubReads = 0, secretReads = 0, secretWrites = 0, unexpectedNetwork = 0, starts = 0;
  let startedCandidates: string[] = [];
  settings.get = <T,>(key: string, fallback: T): T => values.has(key) ? values.get(key) as T : fallback;
  settings.set = (key, value) => { values.set(key, value); };
  ipc.run = async (_executable, args, options) => {
    if (options?.cwd !== path) throw new Error("Unexpected process outside the validation fixture");
    if (args.includes("rev-parse")) return { status: 0, stdout: head + "\n", stderr: "" };
    if (args.includes("diff")) return { status: 0, stdout: diff, stderr: "" };
    if (args.includes("ls-files")) return { status: 0, stdout: "H src/index.ts\0", stderr: "" };
    if (args.includes("status")) return { status: 0, stdout: "", stderr: "" };
    throw new Error("Unexpected process in the validation fixture");
  };
  ipc.http = async () => { unexpectedNetwork++; throw new Error("Unexpected external network request"); };
  ipc.secretGet = async () => { secretReads++; return null; };
  ipc.secretSet = async () => { secretWrites++; };
  ipc.hubRead = async (url, token) => {
    hubReads++;
    if (token !== secret || !url.startsWith("https://hub.example.com/api/v1/repos/example.com/team/app/")) throw new Error("Unexpected hub destination or credential");
    if (hubMode === "error") return { status: 503, body: "Synthetic disconnected hub" };
    const repo = "example.com/team/app", now = Date.now();
    const member = (name: string) => ({ member: name, client: "desktop", branch: "feature/example", head, changed: ["src/index.ts"], related: [], updated: new Date(now - 1000).toISOString(), expires: new Date(now + 60_000).toISOString() });
    const a = member("member-a"), b = member("member-b");
    return { status: 200, body: JSON.stringify(url.endsWith("/presence")
      ? { repo, presence: hubMode === "empty" ? null : [a, b] }
      : { repo, overlaps: hubMode === "empty" ? null : [{ kind: "same-file", a, b, paths: ["src/index.ts"] }] }) };
  };
  store.path = path; store.headHash = head; store.remoteURLs = { origin: "https://example.com/team/app.git" };
  store.commitImpact = { kind: "done", revision: 0, result: {
    schemaVersion: 1, tool: "gitch graph review", scope: "staged", stamp: "staged-fixture", snapshot: "fixture", headSha: head, branch: "feature/example", stale: false,
    changed: [{ path: "src/index.ts", status: "M", analyzed: true }], direct: [], indirect: [], tests: [{ path: "tests/index.test.ts", kind: "dependency", depth: 1, heuristic: false }], coverage: { changed: 1, analyzed: 1, unsupported: 0 }, limitations: [],
  } };
  agents.sessions = ["agent-a", "agent-b"].map((id): AgentSession => ({ id, kind: "codex", path, task: "Synthetic task", mode: "read-only", created: Date.now() / 1000, updated: Date.now() / 1000, status: "working", detail: null }));
  const flows = flowStoreFor(path), stamp = (await worktreeStamp(path)).stamp,
    originalFlows = { refresh: flows.refresh, open: flows.open, startVerified: flows.startVerified };
  flows.hasFlowFile = true;
  flows.list = { project: "fixture", trusted: true, suites: [], flows: [{ name: "check", description: "Synthetic configured check", trigger: [], env: "local", nodes: 1, last: null }] };
  flows.runs = ["current-run", "stale-run", "unbound-run", "unfinished-record"].map((runId) => ({ runId, flow: "check", state: "SUCCEEDED", running: false }));
  for (const run of flows.runs) {
    const record: Record<string, unknown> = { runId: run.runId, state: "SUCCEEDED", git: { sha: head }, finishedAt: new Date().toISOString(), nodes: run.runId === "unbound-run" ? [{ state: "PASSED" }] : [{ tests: { executed: 5, passed: 5, failed: 0 } }] };
    if (run.runId === "unfinished-record") delete record.finishedAt;
    flows.records.set(run.runId, record);
  }
  flows.validationBindings = ["current-run", "stale-run", "unfinished-record"].map((runID) => ({ schemaVersion: 1, runID, head, before: stamp, after: runID === "stale-run" ? "older-fixture-stamp" : stamp, candidates: ["tests/index.test.ts"], observedAt: new Date().toISOString() }));
  flows.refresh = async () => { flows.changed(); };
  flows.open = async () => {};
  flows.startVerified = async (_flow, candidates) => { starts++; startedCandidates = [...candidates]; return "synthetic-start"; };
  return {
    store, flows, secret, stamp, values,
    get hubReads() { return hubReads; }, get secretReads() { return secretReads; }, get secretWrites() { return secretWrites; }, get unexpectedNetwork() { return unexpectedNetwork; }, get starts() { return starts; }, get startedCandidates() { return startedCandidates; },
    hub(mode: typeof hubMode) { hubMode = mode; },
    changedContents(value: string) { diff = value; },
    dispose() {
      ipc.run = original.run; ipc.hubRead = original.hubRead; ipc.http = original.http; ipc.secretGet = original.secretGet; ipc.secretSet = original.secretSet;
      settings.get = original.get; settings.set = original.set; agents.sessions = original.sessions;
      flows.refresh = originalFlows.refresh; flows.open = originalFlows.open; flows.startVerified = originalFlows.startVerified;
    },
  };
}

/** Real work-validation tabs retain honest evidence, explicit hub connection and a sanitized JSON handoff. */
export async function workValidationSelfTest(): Promise<[boolean, string]> {
  const fixture = await workValidationFixture(), host = document.createElement("div"), root = createRoot(host);
  let restoreExtraFlow: (() => void) | undefined;
  host.hidden = true; document.body.append(host);
  const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 25)),
    ensure = (value: boolean, message: string) => { if (!value) throw new Error(message); },
    until = async (condition: () => boolean) => { for (let attempt = 0; attempt < 160; attempt++) { if (condition()) return true; await pause(); } return false; },
    button = (label: string, scope: ParentNode = host) => [...scope.querySelectorAll<HTMLButtonElement>("button")].find((value) => value.textContent?.trim() === t(label)),
    panel = (id: string) => host.querySelector<HTMLElement>(`#work-validation-panel-${id}`)!,
    enter = (element: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, value: string) => {
      const proto = element instanceof HTMLSelectElement ? HTMLSelectElement.prototype : element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(element, value);
      element.dispatchEvent(new Event(element instanceof HTMLSelectElement ? "change" : "input", { bubbles: true }));
    },
    runText = (id: string) => [...(panel("verification")?.querySelectorAll<HTMLElement>(".validation-results [role=listitem]") ?? [])].find((row) => row.textContent?.includes(id))?.textContent ?? "",
    field = (scope: ParentNode, label: string) => [...scope.querySelectorAll<HTMLLabelElement>("label")].find((row) => row.firstChild?.textContent?.trim() === t(label))!.querySelector<HTMLInputElement | HTMLTextAreaElement>("input,textarea")!;
  try {
    root.render(<WorkValidationSheet store={fixture.store} close={() => {}} />);
    ensure(await until(() => runText("current-run").includes(t("Current content"))), "Current verification evidence not rendered");
    ensure(runText("stale-run").includes(t("Stale content")), "Mismatched end stamp was not stale");
    ensure(runText("unfinished-record").includes(t("No content binding")), "A missing end record was presented as current");
    ensure(runText("unbound-run").includes(t("No test execution count was reported.")), "A successful flow invented test execution");
    ensure(fixture.hubReads === 0 && fixture.secretReads === 0 && fixture.secretWrites === 0, "Hub or credential access occurred before explicit Connect");
    enter(panel("verification").querySelector<HTMLSelectElement>(`select[aria-label="${t("Verification flow")}"]`)!, "check"); await pause();
    fixture.store.commitImpact = fixture.store.commitImpact?.kind === "done" ? { ...fixture.store.commitImpact, result: { ...fixture.store.commitImpact.result, stale: true } } : null;
    fixture.store.changed(); await pause();
    ensure(button("Run verification flow")!.disabled, "Stale staged candidates could start verification");
    if (fixture.store.commitImpact?.kind === "done") fixture.store.commitImpact = { ...fixture.store.commitImpact, result: { ...fixture.store.commitImpact.result, stale: false } };
    fixture.store.changed(); await pause();
    button("Run verification flow")!.click();
    ensure(await until(() => fixture.starts === 1), "Configured synthetic flow was not started");
    ensure(await until(() => !button("Run verification flow")!.disabled), "Synthetic verification flow did not settle");
    ensure(fixture.startedCandidates.join() === "tests/index.test.ts", "Verification lost the selected test candidates");
    fixture.changedContents("Synthetic changed tracked contents");
    button("Refresh", panel("verification"))!.click();
    ensure(await until(() => runText("current-run").includes(t("Stale content"))), "Changed working contents remained current");
    fixture.changedContents(""); button("Refresh", panel("verification"))!.click();
    ensure(await until(() => runText("current-run").includes(t("Current content"))), "Restored working snapshot did not refresh");

    button("Team overlap evidence")!.click(); await pause();
    const team = panel("team");
    enter(team.querySelector<HTMLInputElement>(`input[aria-label="${t("Hub URL")}"]`)!, "https://hub.example.com");
    enter(team.querySelector<HTMLInputElement>(`input[aria-label="${t("Hub token")}"]`)!, fixture.secret); await pause();
    ensure(fixture.hubReads === 0 && fixture.secretWrites === 0, "Editing hub fields connected automatically");
    button("Connect and read", team)!.click();
    ensure(await until(() => team.textContent?.includes(t("No overlaps were reported in this snapshot.")) === true), "Empty Go slices did not render an empty snapshot");
    ensure(fixture.hubReads === 2 && fixture.secretWrites === 1, "Explicit hub connection did not use two read resources and the credential store");
    fixture.hub("overlap"); button("Refresh", team)!.click();
    ensure(await until(() => team.textContent?.includes(t("Same-file observation")) === true), "Observed team overlap not shown");
    fixture.hub("error"); button("Refresh", team)!.click();
    ensure(await until(() => team.querySelector("[role=alert]")?.textContent?.includes(t("The team hub is disconnected. Previously observed data may be stale.")) === true), "Failed refresh did not disclose stale hub evidence");
    ensure(team.textContent?.includes("src/index.ts") === true, "Disconnected refresh discarded its observed snapshot");

    button("Agent handoff")!.click(); await pause();
    const agentPanel = panel("agents"), sessions = [...agentPanel.querySelectorAll<HTMLDetailsElement>("details")];
    ensure(sessions.length === 2, "Tracked fixture agent sessions missing");
    for (const session of sessions) session.open = true;
    enter(field(sessions[0], "Task ID"), "TASK-A"); await pause();
    enter(field(sessions[0], "Task goal"), 'Review /home/example/a"b'); await pause();
    const reportToken = "ghp_" + "z".repeat(24);
    enter(field(sessions[0], "Remaining work"), `Review synthetic token ${reportToken}`); await pause();
    for (const [index, scope] of ["src/core", "src/core/graph.ts"].entries()) {
      const paths = field(sessions[index], "Task boundaries · relative paths, one per line");
      enter(paths, scope); paths.dispatchEvent(new FocusEvent("focusout", { bubbles: true })); await pause();
    }
    ensure(agentPanel.textContent?.includes(t("Overlapping task boundaries")) === true, "Explicit agent path overlap not shown");
    const boundary = field(sessions[0], "Task boundaries · relative paths, one per line");
    enter(boundary, "../outside"); await pause();
    ensure(button("Create handoff report", agentPanel)!.disabled && !!agentPanel.querySelector("[role=alert]"), "An invalid boundary draft could be exported without an explanation");
    enter(boundary, "src/core"); await pause();
    button("Create handoff report", agentPanel)!.click(); await pause();
    const report = agentPanel.querySelector<HTMLTextAreaElement>(`textarea[aria-label="${t("Handoff report")}"]`)?.value ?? "";
    const parsed = JSON.parse(report) as { candidates: string[]; verification: { runID: string; executed: number | null }[] };
    ensure(parsed.candidates.includes("tests/index.test.ts") && parsed.verification.some((row) => row.runID === "current-run" && row.executed === 5), "Handoff report lost actual execution evidence or candidate paths");
    ensure(!report.includes(fixture.secret) && !report.includes(reportToken) && !report.includes("/home/example/") && !report.includes(fixture.store.path!), "Handoff exported a secret or local machine path");
    ensure(!JSON.stringify([...fixture.values.values()]).includes(fixture.secret), "Hub token was stored in ordinary settings");
    ensure(fixture.unexpectedNetwork === 0, "Validation UI attempted an external provider request");
    const other = new RepoStore(); other.path = fixture.store.path + "-other"; other.headHash = "b".repeat(40);
    const otherFlow = flowStoreFor(other.path), previousRefresh = otherFlow.refresh;
    otherFlow.refresh = async () => {}; restoreExtraFlow = () => { otherFlow.refresh = previousRefresh; };
    const beforeSwitchReads = fixture.hubReads;
    root.render(<WorkValidationSheet store={other} close={() => {}} />);
    ensure(await until(() => !runText("current-run")), "Prior repository evidence survived the sheet context change");
    button("Agent handoff")!.click(); await pause();
    ensure(button("Create handoff report", panel("agents"))!.disabled, "New repository inherited an old content stamp before its snapshot loaded");
    ensure(fixture.hubReads === beforeSwitchReads, "Repository switch reused an old team connection");
    return [true, "Actual validation tabs distinguish current/stale/unbound/unknown counts, disable stale candidates, start one synthetic configured flow, avoid hub/credentials before Connect, display empty/observed/disconnected hub snapshots and export valid redacted agent handoff JSON with explicit path overlaps."];
  } catch (error) {
    return [false, error instanceof Error ? error.stack ?? error.message : String(error)];
  } finally {
    root.unmount(); host.remove(); restoreExtraFlow?.(); fixture.dispose();
  }
}
