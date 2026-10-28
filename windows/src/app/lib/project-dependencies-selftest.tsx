import { createRoot } from "react-dom/client";
import { localProjects, projectDependencyGraph } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { localPlannerFixture, LocalPlannerFixtureShell } from "./local-planner-fixture";

/** Exercises the actual local roadmap and predecessor editor against isolated atomic persistence. */
export async function projectDependenciesSelfTest(): Promise<[boolean, string]> {
  const fixture = localPlannerFixture(), host = document.createElement("div"), root = createRoot(host);
  host.hidden = true; document.body.append(host);
  const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 25)),
    ensure = (value: boolean, message: string) => { if (!value) throw new Error(message); },
    until = async (condition: () => boolean) => { for (let attempt = 0; attempt < 160; attempt++) { if (condition()) return true; await pause(); } return false; },
    button = (label: string, scope: ParentNode = host) => [...scope.querySelectorAll<HTMLButtonElement>("button")].find((value) => value.textContent?.trim() === t(label)),
    editor = () => host.querySelector<HTMLElement>(".project-dependencies-editor")!,
    duration = () => editor().querySelector<HTMLInputElement>(`input[aria-label="${t("Duration (days)")}"]`)!,
    predecessor = (title: string) => [...editor().querySelectorAll<HTMLLabelElement>(".project-predecessor-choices label")].find((label) => label.textContent?.trim() === title)!.querySelector<HTMLInputElement>("input")!,
    enter = (input: HTMLInputElement, value: string) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
    },
    focus = async (title: string) => {
      [...host.querySelectorAll<HTMLButtonElement>(".project-dependency-task-picker button")].find((value) => value.querySelector("strong")?.textContent === title)!.click();
      ensure(await until(() => host.querySelector(".project-inspector h2")?.textContent === title), "Graph selection did not open the captured task");
      await pause();
    },
    saved = async () => {
      ensure(await until(() => !fixture.store.hostingHub.busy && !fixture.store.hostingHub.detailLoading && !editor()?.querySelector("fieldset")?.disabled), "Dependency save did not settle");
      await pause();
    };
  const originalWrite = ipc.localProjectsWrite;
  try {
    const project = await localProjects.create("Synthetic dependency plan");
    let detail = await localProjects.detail(project.id);
    detail = await localProjects.saveDraft(detail, "Outline", "");
    detail = await localProjects.saveDraft(detail, "Implementation", "");
    await fixture.store.hostingHub.selectProjectSource("local");
    await fixture.store.hostingHub.select(detail.item);
    root.render(<LocalPlannerFixtureShell fixture={fixture} />);
    ensure(await until(() => !!button("Timeline")), "Roadmap navigation missing");
    button("Timeline")!.click();
    ensure(await until(() => !!host.querySelector(".project-dependency-view")), "Local roadmap dependency graph missing");
    await focus("Implementation");
    predecessor("Outline").click(); enter(duration(), "3"); await pause();
    ipc.localProjectsWrite = async () => { throw new Error("Synthetic dependency save failure"); };
    button("Save task dependencies", editor())!.click(); await saved();
    ensure(duration().value === "3" && predecessor("Outline").checked && !!editor().querySelector("[role=alert]"), "Failed dependency save lost its draft");
    ipc.localProjectsWrite = originalWrite;
    const writes = fixture.writes;
    button("Save task dependencies", editor())!.click(); button("Save task dependencies", editor())?.click(); await saved();
    ensure(fixture.writes === writes + 1 && !host.querySelector(".hub-confirm"), "Dependency submit wrote twice or opened an unnecessary review");
    let current = fixture.store.hostingHub.detail!;
    ensure(projectDependencyGraph(current.rows).nodes.find((node) => node.row.title === "Implementation")?.blockedBy.length === 1, "Incomplete predecessor did not block its successor");
    await focus("Outline"); enter(duration(), "2"); await pause();
    button("Save task dependencies", editor())!.click(); await saved();
    ensure(host.querySelector(".project-dependency-view")?.textContent?.includes(t("Critical path: {0} days", 5)) === true, "Explicit critical path not shown");
    predecessor("Implementation").click(); await pause();
    const beforeCycle = fixture.writes;
    button("Save task dependencies", editor())!.click(); await saved();
    ensure(fixture.writes === beforeCycle && editor().querySelector("[role=alert]")?.textContent?.includes(t("These predecessor links would create a cycle.")) === true && predecessor("Implementation").checked, "Cycle was saved or its failed draft was lost");
    predecessor("Implementation").click(); await pause();
    const status = [...host.querySelectorAll<HTMLSelectElement>(".project-field-editor select")].find((select) => [...select.options].some((option) => option.value === "local-done"))!;
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(status, "local-done");
    status.dispatchEvent(new Event("change", { bubbles: true })); await pause(); await saved();
    current = fixture.store.hostingHub.detail!;
    const graph = projectDependencyGraph(current.rows);
    ensure(graph.durationDays === 3 && !graph.nodes.find((node) => node.row.title === "Implementation")?.blockedBy.length, "Completed predecessor did not release its successor");
    const reopened = await fixture.reopen(), restored = await reopened.detail(project.id);
    ensure(restored.rows[1].durationDays === 3 && restored.rows[1].predecessorIDs?.[0] === restored.rows[0].id, "Dependency metadata did not survive restart");
    ensure(fixture.http === 0 && fixture.credentials === 0 && fixture.remoteWrites === 0, "Local predecessor planning accessed an account or network");
    return [true, "Local roadmap relationships open task details; predecessor/duration edits persist atomically, retain failed drafts, reject cycles, guard repeated submit and derive readiness/critical path without date writes, network or credentials."];
  } catch (error) {
    return [false, error instanceof Error ? error.stack ?? error.message : String(error)];
  } finally {
    ipc.localProjectsWrite = originalWrite; root.unmount(); host.remove(); fixture.restore();
  }
}
