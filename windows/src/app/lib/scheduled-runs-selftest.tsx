import { createRoot } from "react-dom/client";
import type { ReactNode } from "react";
import { type CIWorkflow, dateTimeInputValue, nextFullHour, type ScheduledRun, scheduledRunRelative, scheduledRuns, scheduledRunTime } from "@/entities/ci";
import type { RepoTarget } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { CIPanel } from "@/features/ci-panel";
import { RunPipelineSheet } from "@/features/run-pipeline";
import { t } from "@/shared/i18n";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 60));

/**
 * Run later in the run sheet (GitHub and GitLab) and the Actions page's Scheduled group, on the schedule's own clock and
 * list: nothing reaches a server, and a start only records which run it was.
 */
export async function scheduledRunsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  host.hidden = true;
  document.body.append(host);
  let root = createRoot(host);
  const now = new Date(2026, 10, 10, 14, 20).getTime();
  const state = { now, runs: [] as ScheduledRun[], started: [] as string[], failing: new Set<string>() };
  const previous = scheduledRuns.useHost({
    now: () => state.now,
    read: () => state.runs,
    write: (runs) => { state.runs = runs; },
    start: async (run) => { state.started.push(run.id); if (state.failing.has(run.id)) throw new Error("Fixture refusal"); },
  });
  const previousStarted = scheduledRuns.onStarted;
  const store = new RepoStore();
  const profile = { id: "scheduled-fixture", provider: "github" as const, server: "https://github.com", username: "fixture", name: null, avatarURL: null };
  const github: RepoTarget = { provider: "github", host: "github.com", remote: "origin", path: "fixture/scheduled" };
  const workflow: CIWorkflow = { id: 42, name: "Deploy", path: ".github/workflows/deploy.yml", inputs: [{ name: "level", description: "", required: false, defaultValue: "info", type: "choice", options: ["info", "debug"] }] };
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const until = async (test: () => unknown) => {
    const deadline = Date.now() + 3500;
    while (!test() && Date.now() < deadline) await pause();
    return !!test();
  };
  const mount = async (node: ReactNode) => { root.render(node); await pause(); await pause(); };
  const reset = () => { root.unmount(); host.replaceChildren(); root = createRoot(host); };
  const button = (label: string, scope: ParentNode = host) => [...scope.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.trim() === t(label));
  const change = async (element: HTMLInputElement, value: string) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(element, value);
    element.dispatchEvent(new Event("input", { bubbles: true }));
    await pause();
  };
  const row = (id: string) => host.querySelector<HTMLElement>(`.ci-scheduled-run[data-scheduled="${id}"]`);
  try {
    store.path = "C:/fixture/scheduled";
    store.target = github;
    Object.defineProperty(store, "hostingAccount", { get: () => profile });
    Object.defineProperty(store.ci, "branches", { get: () => ["main"] });
    store.ci.workflows = async () => [workflow];
    store.ci.gitlabVariables = async () => [{ name: "DEPLOY_ENV", description: "", required: false, defaultValue: "staging", type: "string", options: [] }];
    store.ci.load = async () => {};

    // GitHub: Run later offers the next full hour, refuses a time gone by and keeps the ref and the inputs
    let closed = 0;
    await mount(<RunPipelineSheet store={store} close={() => { closed++; }} />);
    check(await until(() => host.querySelector("select option[value='42']")), "The sheet did not list the workflow");
    check(button("Run") && !host.querySelector("#run-later-at"), "The sheet must start on Run now");
    button("Run later")!.click();
    check(await until(() => host.querySelector("#run-later-at")), "Run later did not show the date and time");
    const field = host.querySelector<HTMLInputElement>("#run-later-at")!;
    check(field.value === dateTimeInputValue(nextFullHour(now)), `Run later must offer the next full hour, not ${field.value}`);
    check(button("Schedule run") && !button("Run"), "Run later must turn the primary into Schedule run");
    await change(field, dateTimeInputValue(now - 3_600_000));
    check(await until(() => button("Schedule run")?.disabled && host.textContent?.includes(t("Choose a time in the future."))), "A time gone by must disable Schedule run and say why");
    const runAt = now + 2 * 3_600_000 + 10 * 60_000;
    await change(field, dateTimeInputValue(runAt));
    check(await until(() => button("Schedule run")?.disabled === false), "A time ahead must enable Schedule run");
    button("Schedule run")!.click();
    check(await until(() => closed === 1 && state.runs.length === 1), `Schedule run did not keep the run: ${JSON.stringify(state.runs)}`);
    const kept = state.runs[0];
    check(kept.provider === "github" && kept.workflowID === 42 && kept.workflowName === "Deploy" && kept.ref === "main" && kept.inputs.level === "info"
      && kept.runAt === runAt && kept.accountID === profile.id && kept.repoPath === store.path && kept.state === "scheduled", `The kept run is wrong: ${JSON.stringify(kept)}`);
    check(state.started.length === 0, "Scheduling must not start the run");
    reset();

    // GitLab: the same, with the pipeline's variables
    store.target = { ...github, provider: "gitlab", host: "gitlab.example.com" };
    closed = 0;
    await mount(<RunPipelineSheet store={store} close={() => { closed++; }} />);
    check(await until(() => host.textContent?.includes("DEPLOY_ENV")), "The pipeline sheet did not read its variables");
    button("Run later")!.click();
    check(await until(() => button("Schedule run")?.disabled === false), "Run later on a pipeline must offer a time ahead");
    button("Schedule run")!.click();
    check(await until(() => closed === 1 && state.runs.length === 2), "Schedule run did not keep the pipeline");
    const pipeline = state.runs[1];
    check(pipeline.provider === "gitlab" && pipeline.workflowID === null && JSON.stringify(pipeline.variables) === JSON.stringify([["DEPLOY_ENV", "staging"]])
      && pipeline.runAt === nextFullHour(now), `The kept pipeline is wrong: ${JSON.stringify(pipeline)}`);
    reset();

    // the Scheduled group lists this repository's runs with their time, and Cancel removes one
    store.target = github;
    await mount(<CIPanel store={store} openSettings={() => {}} page />);
    check(await until(() => row(kept.id)), "The Scheduled group did not list the run");
    const keptRow = row(kept.id)!;
    check(keptRow.textContent?.includes("Deploy") && keptRow.textContent.includes("main")
      && keptRow.textContent.includes(scheduledRunTime(runAt, now)) && keptRow.textContent.includes(scheduledRunRelative(runAt, now)), `The row must name the workflow, branch and time: ${keptRow.textContent}`);
    check(row(pipeline.id)?.textContent?.includes(t("Pipeline")), "A pipeline row must say Pipeline");
    check(button("Cancel", keptRow) && !button("Run now", keptRow), "A scheduled run offers Cancel only");
    button("Cancel", keptRow)!.click();
    check(await until(() => !row(kept.id) && state.runs.length === 1), "Cancel did not remove the run");

    // a check starts what is due and marks a run found too late as missed, which waits for Run now
    const started: string[] = [];
    scheduledRuns.onStarted = (run) => started.push(run.id);
    state.runs = [{ ...kept, id: "slept", runAt: now - 10 * 60_000 }, { ...kept, id: "due", runAt: now + 30_000 }, { ...kept, id: "refused", runAt: now + 30_000 }];
    state.failing.add("refused");
    state.now = now + 60_000;
    await scheduledRuns.check();
    check(state.started.join() === "due,refused" && started.join() === "due", `The check started the wrong runs: ${state.started}`);
    check(await until(() => !row("due") && row("slept")?.dataset.state === "missed" && row("refused")?.dataset.state === "failed"), "The group did not show the missed and failed runs");
    const slept = row("slept")!, refused = row("refused")!;
    check(slept.textContent?.includes(t("Missed")) && button("Run now", slept) && button("Remove", slept) && !button("Cancel", slept), "A missed run offers Run now and Remove");
    check(refused.textContent?.includes(t("Failed")) && refused.textContent.includes("Fixture refusal"), "A failed run must say why");
    button("Run now", slept)!.click();
    await pause();
    check(store.confirm?.title === t("Start this run now?") && state.started.length === 2, "Run now must ask before it starts the run");
    await store.confirm!.action();
    check(await until(() => !row("slept") && started.join() === "due,slept"), "Run now did not start the missed run");
    button("Remove", refused)!.click();
    check(await until(() => !host.querySelector(".ci-scheduled") && state.runs.length === 0), "Remove did not clear the last run, or the empty group still shows");
    return [true, "Run later on both forms, the Scheduled group, missed and failed runs"];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally {
    scheduledRuns.onStarted = previousStarted;
    scheduledRuns.useHost(previous);
    store.confirm = null;
    root.unmount();
    host.remove();
  }
}
