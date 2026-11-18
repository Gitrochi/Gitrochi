import { createRoot } from "react-dom/client";
import type { ReactNode } from "react";
import {
  type CIJob, type CIPipeline, type CIWorkflow, type CommitRun, dateTimeInputValue, nextFullHour, type RunCommit, type ScheduledRun, scheduledRunRelative,
  scheduledRuns, scheduledRunTime,
} from "@/entities/ci";
import type { RepoTarget } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { CIPanel } from "@/features/ci-panel";
import { RunPipelineSheet } from "@/features/run-pipeline";
import { t } from "@/shared/i18n";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 60));

/**
 * Run later in the run sheet (GitHub and GitLab), running a chosen commit again now or later, and the Actions page's
 * Scheduled group, on the schedule's own clock and list: nothing reaches a server, and a start only records which run it was.
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
  const choose = async (select: HTMLSelectElement, value: string) => {
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
    select.dispatchEvent(new Event("change", { bubbles: true }));
    await pause();
  };
  const select = (id: string) => host.querySelector<HTMLSelectElement>(`#${id}`);
  const note = () => host.querySelector("[data-run-commit-note]")?.textContent ?? "";
  // the commit of 11:00 on main, whose pipeline waits on a manual build job (GitLab) or whose Deploy run finished (GitHub)
  const older = "0123456789abcdef0123456789abcdef01234567";
  const runOf = (id: number, name: string): CIPipeline => ({ id, number: id, name, title: "Fix the deploy", ref: "main", sha: older, status: "success", url: "", created: now / 1000 - 5400, event: "push", actor: null });
  const commits: RunCommit[] = [{ sha: older, subject: "Fix the deploy", created: now / 1000 - 5400, runs: [runOf(4242, "Deploy"), runOf(4241, "CI")] }];
  const jobs: CIJob[] = [
    { id: 8, name: "build-job", stage: "build", status: "manual", url: "", allowFailure: false, duration: null },
    { id: 5, name: "test", stage: "test", status: "success", url: "", allowFailure: false, duration: null },
  ];
  const rerun: CommitRun[] = [];
  try {
    store.path = "C:/fixture/scheduled";
    store.target = github;
    Object.defineProperty(store, "hostingAccount", { get: () => profile });
    Object.defineProperty(store.ci, "branches", { get: () => ["main"] });
    store.ci.workflows = async () => [workflow];
    store.ci.gitlabVariables = async () => [{ name: "DEPLOY_ENV", description: "", required: false, defaultValue: "staging", type: "string", options: [] }];
    store.ci.load = async () => {};
    store.ci.commits = async (branch) => (branch === "main" ? commits : []);
    store.ci.commitJobs = async (pipeline) => (pipeline === 4242 ? jobs : []);
    store.ci.runOnCommit = async (run) => { rerun.push(run); };

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
    check(kept.provider === "github" && kept.workflowID === 42 && kept.workflowName === "Deploy" && kept.ref === "main" && kept.sha === null && kept.runID === null && kept.inputs.level === "info"
      && kept.runAt === runAt && kept.accountID === profile.id && kept.repoPath === store.path && kept.state === "scheduled", `The kept run is wrong: ${JSON.stringify(kept)}`);
    check(state.started.length === 0, "Scheduling must not start the run");
    reset();

    // GitHub, a chosen commit: the branch's tip by default; the commit's run is re-run with its original inputs
    closed = 0;
    await mount(<RunPipelineSheet store={store} close={() => { closed++; }} />);
    check(await until(() => select("run-commit")?.querySelector(`option[value='${older}']`)), "The sheet did not list the commits with runs");
    check(select("run-commit")!.value === "" && select("run-commit")!.options[0].textContent === t("Latest on {0}", "main"), "The commit must start on Latest on main");
    check(select("run-commit")!.options[1].textContent?.startsWith("0123456  Fix the deploy"), "A commit reads as its short SHA and subject");
    await choose(select("run-commit")!, older);
    check(await until(() => select("run-commit-run")?.value === "4242"), "A chosen commit must offer its newest workflow run");
    check(!host.querySelector("select option[value='42']") && !host.textContent?.includes("level"), "A re-run takes no workflow or inputs");
    check(note() === t("Re-runs this run of {0} on {1} with its original inputs.", "0123456", "main"), `The note must say the run repeats: ${note()}`);
    button("Run")!.click();
    check(await until(() => closed === 1 && rerun.length === 1), "Run did not re-run the commit's run");
    check(rerun[0].runID === 4242 && rerun[0].jobName === null, `Run must re-run the chosen run: ${JSON.stringify(rerun)}`);
    reset();

    // Run later keeps the commit and its run
    closed = 0;
    await mount(<RunPipelineSheet store={store} close={() => { closed++; }} />);
    check(await until(() => select("run-commit")?.querySelector(`option[value='${older}']`)), "The sheet did not list the commits again");
    await choose(select("run-commit")!, older);
    check(await until(() => select("run-commit-run")?.value === "4242"), "The run was not chosen again");
    button("Run later")!.click();
    check(await until(() => button("Schedule run")?.disabled === false), "Run later on a commit must offer a time ahead");
    button("Schedule run")!.click();
    check(await until(() => closed === 1 && state.runs.length === 2), "Schedule run did not keep the run on a commit");
    const onCommit = state.runs[1];
    check(onCommit.sha === older && onCommit.runID === 4242 && onCommit.jobName === null && onCommit.workflowName === "Deploy" && onCommit.workflowID === null
      && state.started.length === 0 && rerun.length === 1, `The kept run must keep its commit and run: ${JSON.stringify(onCommit)}`);
    reset();

    // GitLab: the same, with the pipeline's variables
    store.target = { ...github, provider: "gitlab", host: "gitlab.example.com" };
    closed = 0;
    await mount(<RunPipelineSheet store={store} close={() => { closed++; }} />);
    check(await until(() => host.textContent?.includes("DEPLOY_ENV")), "The pipeline sheet did not read its variables");
    button("Run later")!.click();
    check(await until(() => button("Schedule run")?.disabled === false), "Run later on a pipeline must offer a time ahead");
    button("Schedule run")!.click();
    check(await until(() => closed === 1 && state.runs.length === 3), "Schedule run did not keep the pipeline");
    const pipeline = state.runs[2];
    check(pipeline.provider === "gitlab" && pipeline.workflowID === null && JSON.stringify(pipeline.variables) === JSON.stringify([["DEPLOY_ENV", "staging"]])
      && pipeline.runAt === nextFullHour(now), `The kept pipeline is wrong: ${JSON.stringify(pipeline)}`);
    reset();

    // GitLab, a chosen commit: its pipeline's manual job is pressed, now or later, without new variables
    closed = 0;
    await mount(<RunPipelineSheet store={store} close={() => { closed++; }} />);
    check(await until(() => select("run-commit")?.querySelector(`option[value='${older}']`)), "The pipeline sheet did not list the commits");
    await choose(select("run-commit")!, older);
    check(await until(() => select("run-commit-job")?.value === "build-job"), "The manual job must come chosen");
    check(select("run-commit-job")!.options[0].value === "build-job" && !host.textContent?.includes("DEPLOY_ENV"), "Manual jobs come first, and pressing one takes no variables");
    check(note() === t("Presses this job in the pipeline of {0} on {1}.", "0123456", "main"), `The note must say the job is pressed: ${note()}`);
    await choose(select("run-commit-job")!, "test");
    check(await until(() => note() === t("Runs this job again in the pipeline of {0} on {1}.", "0123456", "main")), "A finished job runs again");
    await choose(select("run-commit-job")!, "build-job");
    button("Run")!.click();
    check(await until(() => closed === 1 && rerun.length === 2), "Run did not press the job");
    check(rerun[1].runID === 4242 && rerun[1].jobName === "build-job", `Run must press the chosen job: ${JSON.stringify(rerun)}`);
    reset();
    closed = 0;
    await mount(<RunPipelineSheet store={store} close={() => { closed++; }} />);
    check(await until(() => select("run-commit")?.querySelector(`option[value='${older}']`)), "The pipeline sheet did not list the commits again");
    await choose(select("run-commit")!, older);
    check(await until(() => select("run-commit-job")?.value === "build-job"), "The manual job must come chosen again");
    button("Run later")!.click();
    check(await until(() => button("Schedule run")?.disabled === false), "Run later on a job must offer a time ahead");
    button("Schedule run")!.click();
    check(await until(() => closed === 1 && state.runs.length === 4), "Schedule run did not keep the job");
    const pressed = state.runs[3];
    check(pressed.sha === older && pressed.runID === 4242 && pressed.jobName === "build-job" && pressed.variables.length === 0, `The kept job is wrong: ${JSON.stringify(pressed)}`);
    reset();

    // the Scheduled group lists this repository's runs with their time, and Cancel removes one
    store.target = github;
    await mount(<CIPanel store={store} openSettings={() => {}} page />);
    check(await until(() => row(kept.id)), "The Scheduled group did not list the run");
    const keptRow = row(kept.id)!;
    check(keptRow.textContent?.includes("Deploy") && keptRow.textContent.includes("main")
      && keptRow.textContent.includes(scheduledRunTime(runAt, now)) && keptRow.textContent.includes(scheduledRunRelative(runAt, now)), `The row must name the workflow, branch and time: ${keptRow.textContent}`);
    check(row(pipeline.id)?.textContent?.includes(t("Pipeline")), "A pipeline row must say Pipeline");
    check(!keptRow.querySelector(".ci-scheduled-sha") && row(onCommit.id)?.querySelector(".ci-scheduled-sha")?.textContent === "0123456",
      "Only a run on a commit shows its short SHA");
    check(row(pressed.id)?.querySelector(".ci-scheduled-title")?.textContent === "build-job", "A pressed job is named by the job");
    check(button("Cancel", keptRow) && !button("Run now", keptRow), "A scheduled run offers Cancel only");
    button("Cancel", keptRow)!.click();
    check(await until(() => !row(kept.id) && state.runs.length === 3), "Cancel did not remove the run");

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
    return [true, "Run later on both forms, a chosen commit's run or job now and later, the Scheduled group, missed and failed runs"];
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
