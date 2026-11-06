import { createRoot } from "react-dom/client";
import { t } from "@/shared/i18n";
import {
  planningFixture,
  PlanningFixtureShell,
} from "./project-planning-fixture";
const pause = (ms = 25) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));
/** Home and Projects are mounted together to verify the real task handoff without remote writes. */
export async function projectPlanningSelfTest(): Promise<[boolean, string]> {
  const fixture = planningFixture({ organization: true }),
    host = document.createElement("div");
  host.hidden = true;
  document.body.append(host);
  const root = createRoot(host);
  const ensure = (value: boolean, message: string) => {
      if (!value) throw new Error(message);
    },
    until = async (test: () => boolean) => {
      for (let i = 0; i < 160; i++) {
        if (test()) return true;
        await pause();
      }
      return false;
    },
    button = (label: string) =>
      [...host.querySelectorAll<HTMLButtonElement>("button")].find(
        (value) => value.textContent?.trim() === t(label),
      ),
    search = () =>
      host.querySelector<HTMLInputElement>(
        `input[aria-label="${t("Search tasks and projects")}"]`,
      )!,
    enter = (value: string) => {
      Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value",
      )!.set!.call(search(), value);
      search().dispatchEvent(new Event("input", { bubbles: true }));
    },
    metricCounts = () =>
      [...host.querySelectorAll(".planning-metrics strong")].map((value) =>
        Number(value.textContent),
      );
  try {
    root.render(<PlanningFixtureShell fixture={fixture} />);
    ensure(
      await until(() => !!host.querySelector(".planning-dashboard")),
      "Home planning dashboard missing",
    );
    ensure(fixture.store.target === null && fixture.store.path === null, "Organization planning unexpectedly required a repository");
    ensure(host.querySelector<HTMLSelectElement>(`select[aria-label="${t("Project scope")}"]`)?.value === "organization:team", "Home did not preserve its organization scope without a repository");
    const organizationScope = host.querySelector<HTMLSelectElement>(`select[aria-label="${t("Project scope")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(organizationScope, "other");
    organizationScope.dispatchEvent(new Event("change", { bubbles: true }));
    ensure(await until(() => !!host.querySelector(`input[aria-label="${t("Organization login")}"]`)), "Manual organization entry missing");
    const enterOrganization = (value: string) => {
      const organizationInput = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Organization login")}"]`)!;
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(organizationInput, value);
      organizationInput.dispatchEvent(new Event("input", { bubbles: true }));
    };
    enterOrganization("invalid/organization"); await pause();
    ensure(button("Open organization")!.disabled, "Invalid organization login was accepted");
    enterOrganization("TEAM"); await pause(); button("Open organization")!.click();
    ensure(await until(() => host.querySelector<HTMLSelectElement>(`select[aria-label="${t("Project scope")}"]`)?.value === "organization:team"), "Organization login casing changed the visible scope");
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(organizationScope, "other");
    organizationScope.dispatchEvent(new Event("change", { bubbles: true })); await pause();
    enterOrganization("shared-team"); await pause(); button("Open organization")!.click();
    ensure(await until(() => host.querySelector<HTMLSelectElement>(`select[aria-label="${t("Project scope")}"]`)?.value === "organization:shared-team"), "An organization outside the membership list could not be selected");
    const scope = host.querySelector<HTMLSelectElement>(`select[aria-label="${t("Project scope")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(scope, "organization:team");
    scope.dispatchEvent(new Event("change", { bubbles: true })); await pause();
    ensure(
      JSON.stringify(metricCounts()) === JSON.stringify([1, 1, 2, 1, 1]),
      "Home metrics did not deduplicate shared issues",
    );
    ensure(
      host.querySelectorAll(".planning-agenda .planning-task").length === 5,
      "Default agenda lost or duplicated active work",
    );
    enter("Shared delivery task");
    await pause();
    ensure(
      host.querySelectorAll(".planning-task").length === 1,
      "Shared task search showed duplicates",
    );
    ensure(
      host
        .querySelector(".planning-task small")
        ?.textContent?.includes("Product quality") === true &&
        host
          .querySelector(".planning-task small")
          ?.textContent?.includes("Release engineering") === true,
      "Shared task lost its project names",
    );
    enter("");
    await pause();
    button("Assigned to me")!.click();
    await pause();
    ensure(
      host.querySelectorAll(".planning-task").length === 2,
      "Assigned-to-me did not filter actual task assignees",
    );
    button("Assigned to me")!.click();
    await pause();
    host
      .querySelector<HTMLButtonElement>(".planning-metrics .overdue")!
      .click();
    await pause();
    ensure(
      host.querySelectorAll(".planning-task").length === 1 &&
        host.querySelector(".planning-task strong")?.textContent ===
          "Resolve release blockers",
      "Overdue focus did not show the correct task",
    );
    button("Clear filter")!.click();
    await pause();
    button("Week")!.click();
    await pause();
    ensure(
      host.querySelectorAll(".planning-week>article").length === 7,
      "Home week did not show seven calendar days",
    );
    const firstDay = host.querySelector(".planning-week h4")?.textContent;
    host
      .querySelector<HTMLButtonElement>(`button[data-tip="${t("Next week")}"]`)!
      .click();
    await pause();
    ensure(
      host.querySelector(".planning-week h4")?.textContent !== firstDay,
      "Week navigation did not advance",
    );
    button("Today")!.click();
    await pause();
    ensure(
      host.querySelector(".planning-week h4")?.textContent === firstDay,
      "Today did not return to the current week",
    );
    button("Projects")!.click();
    await pause();
    ensure(
      host.querySelectorAll(".planning-projects>article").length === 2,
      "Project portfolio cards missing",
    );
    fixture.data.setSelected([...fixture.data.selectedIDs, "MISSING"]);
    await pause();
    ensure(
      !!button("Remove unavailable selections"),
      "Unavailable saved project selection could not be removed",
    );
    button("Remove unavailable selections")!.click();
    ensure(
      await until(
        () =>
          !fixture.data.loading &&
          !fixture.data.selectedIDs.includes("MISSING"),
      ),
      "Unavailable selection remained saved",
    );
    const picker = host.querySelector<HTMLDetailsElement>(
      ".planning-project-picker",
    )!;
    picker.open = true;
    const projectCheckbox = host.querySelectorAll<HTMLInputElement>(
      ".planning-project-picker input",
    )[1];
    projectCheckbox.click();
    ensure(
      await until(
        () => fixture.data.details.length === 1 && !fixture.data.loading,
      ),
      "Project selection did not update the portfolio",
    );
    await pause();
    host
      .querySelectorAll<HTMLInputElement>(".planning-project-picker input")[1]
      .click();
    ensure(
      await until(
        () => fixture.data.details.length === 2 && !fixture.data.loading,
      ),
      "Re-selected project did not restore its tasks",
    );
    button("Agenda")!.click();
    await pause();
    enter("Shared delivery task");
    await pause();
    host.querySelector<HTMLButtonElement>(".planning-task")!.click();
    ensure(
      await until(
        () =>
          fixture.store.destination === "projects" &&
          !!host.querySelector(".project-inspector"),
      ),
      "Home did not open the exact task in Projects",
    );
    ensure(fixture.store.hostingHub.projectScope === "organization:team", "Home lost organization scope during navigation to Projects");
    ensure(
      fixture.store.hostingHub.detail?.item.id === "QUALITY" &&
        fixture.store.hostingHub.requestedProjectRowID === null &&
        fixture.itemPages > 0,
      "Home did not choose the project with the earliest active date",
    );
    ensure(
      host.querySelector(".project-inspector h2")?.textContent ===
        "Shared delivery task",
      "Task inspector did not retain the Home handoff",
    );
    host
      .querySelector<HTMLButtonElement>(
        `.project-inspector button[data-tip="${t("Close task details")}"]`,
      )!
      .click();
    await pause();
    fixture.store.navigate("home");
    await pause();
    fixture.store.navigate("projects");
    ensure(
      await until(() => !!host.querySelector(".project-workspace")),
      "Project panel did not remount",
    );
    ensure(
      !host.querySelector(".project-inspector") &&
        fixture.store.hostingHub.requestedProjectRowID === null,
      "Consumed Home task request reopened its inspector on remount",
    );
    ensure(fixture.writes === 0, "Home planning issued a remote mutation");
    return [
      true,
      "Organization Home without a repository + preserved organization project/task handoff + Home deduplicated metrics + task/project search + assignee and overdue filters + week navigation + project selection persistence + unavailable selection removal + exact earliest-date page-2 project/task handoff + one-time inspector focus without remote writes",
    ];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally {
    root.unmount();
    host.remove();
    fixture.restore();
    try {
      localStorage.removeItem(
        `gitrochi.project-portfolio-selection.v1:${fixture.selectionContext}`,
      );
    } catch {
      /* Only isolated fixture preferences. */
    }
  }
}

/** Exercises a real three-page organization project through Home and the complete task table. */
export async function projectItemCompletenessSelfTest(): Promise<[boolean, string]> {
  const fixture = planningFixture({organization:true,complete:true}), host = document.createElement("div");
  host.hidden = true; document.body.append(host);
  const root = createRoot(host), ensure = (condition:boolean,message:string) => {if(!condition)throw new Error(message);};
  const until = async (test:() => boolean) => {for(let i=0;i<160;i++){if(test())return true;await pause();}return false;};
  const button = (label:string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find(item => item.textContent?.trim() === t(label));
  try {
    await fixture.load();
    ensure(fixture.store.target === null && fixture.data.details[0].rows.length === 203 && !fixture.data.details[0].more, "Organization project did not load every issue, draft, archived item and restricted placeholder");
    ensure(fixture.itemPages === 2, "Home did not read all three project pages");
    root.render(<PlanningFixtureShell fixture={fixture}/>);
    ensure(await until(() => host.querySelectorAll(".planning-agenda .planning-task").length === 16), "Home agenda preview missing");
    let expanded = 0;
    while (button("Show more tasks") && expanded < 10) {button("Show more tasks")!.click();expanded++;await pause();}
    ensure(host.querySelectorAll(".planning-agenda .planning-task").length === 67 && !button("Show more tasks"), "Home agenda could not expose every active task after its first sixteen");
    ensure(host.querySelector(".planning-agenda")?.textContent?.includes("Final planning draft") === true, "The later-page draft remained hidden in Home");
    fixture.store.navigate("projects");
    ensure(await until(() => host.querySelectorAll(".project-list .project-table-row").length === 103), "Fresh GitHub Projects did not open the complete unarchived task table");
    ensure(fixture.store.hostingHub.detail?.rows.length === 203 && fixture.store.hostingHub.projectScope === "organization:team", "Projects lost the complete organization snapshot");
    ensure(host.querySelector(".project-list")?.textContent?.includes("Delivery task 1") === true && host.querySelector(".project-list")?.textContent?.includes("Final planning draft") === true, "Closed issues or later drafts were absent from the task table");
    button("Overview")!.click(); await pause();
    const search = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Search tasks")}"]`)!;
    const type = (value:string) => {Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value")!.set!.call(search,value); search.dispatchEvent(new Event("input",{bubbles:true}));};
    type("does-not-match");await pause();
    button("Table")!.click();
    ensure(await until(() => !!host.querySelector(".project-list") && host.querySelectorAll(".project-list .project-table-row").length === 0), "The search did not follow the task table");
    type("");await pause();
    // Archived items are a choice of the Filter menu, which the app mounts at its root.
    const archived = () => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find(item => item.querySelector(".label")?.textContent === t("Include archived"));
    button("Filter")!.click();
    ensure(await until(() => !!archived()), "The Filter menu did not offer archived items");
    archived()!.click();
    ensure(await until(() => host.querySelectorAll(".project-list .project-table-row").length === 203), "Including archived items did not show the whole project");
    ensure(fixture.writes === 0, "Reading the complete project or changing views mutated GitHub");
    return [true,"Three project pages + 203 mixed items without a repository + expandable Home agenda + fresh full task table including closed issues and late draft + the search follows the table and the Filter menu includes archived items"];
  } catch (error) {return [false,error instanceof Error ? error.message : String(error)];}
  finally {root.unmount();host.remove();fixture.restore();}
}
