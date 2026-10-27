import { createRoot } from "react-dom/client";
import {
  localProjects,
  localScheduleToday,
  scheduleAddDays,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { ipc } from "@/shared/api";
import {
  localPlannerFixture,
  LocalPlannerFixtureShell,
} from "./local-planner-fixture";
const pause = (ms = 25) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));
/** Account-free editing, durable reload, and honest remote creation choices exercise the actual components. */
export async function localPlannerSelfTest(): Promise<[boolean, string]> {
  const fixture = localPlannerFixture(),
    host = document.createElement("div");
  host.hidden = true;
  document.body.append(host);
  const root = createRoot(host);
  const ensure = (condition: boolean, message: string) => {
      if (!condition) throw new Error(message);
    },
    until = async (test: () => boolean) => {
      for (let i = 0; i < 160; i++) {
        if (test()) return true;
        await pause();
      }
      return false;
    };
  const button = (label: string, scope: ParentNode = host) =>
    [...scope.querySelectorAll<HTMLButtonElement>("button")].find(
      (value) => value.textContent?.trim() === t(label) || value.getAttribute("aria-label") === t(label) || (label === "Confirm" && value.matches(".project-create-review footer > button:last-child")),
    );
  const input = (label: string) =>
    host.querySelector<HTMLInputElement>(`input[aria-label="${t(label)}"]`)!;
  const enter = (
    element: HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement,
    value: string,
  ) => {
    const proto =
      element instanceof HTMLSelectElement
        ? HTMLSelectElement.prototype
        : element instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype
          : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(element, value);
    element.dispatchEvent(
      new Event(element instanceof HTMLSelectElement ? "change" : "input", {
        bubbles: true,
      }),
    );
  };
  const saved = async () => {
    await pause();
    ensure(!host.querySelector(".hub-confirm"), "An editor opened an extra confirmation");
    ensure(await until(() => !fixture.store.hostingHub.busy && !fixture.store.hostingHub.detailLoading), "Local save did not finish");
    await pause();
  };
  const editor = (id: string) => {
    const field = fixture.store.hostingHub.detail!.fields.find(
      (value) => value.id === id,
    )!;
    return [
      ...host.querySelectorAll<HTMLLabelElement>(".project-field-editor"),
    ].find((value) => value.querySelector("span")?.textContent === field.name)!;
  };
  try {
    root.render(<LocalPlannerFixtureShell fixture={fixture} />);
    ensure(
      await until(() => !!button("New project")),
      "Project workspace missing",
    );
    button("New project")!.click();
    await pause();
    ensure(
      host.querySelectorAll(".project-create-mode").length === 3,
      "Creation source choices missing",
    );
    ensure(
      host
        .querySelector(".project-create-mode.selected")
        ?.textContent?.includes(t("Local project")) === true,
      "Local mode not selected",
    );
    enter(input("Project name"), "Offline release plan");
    await pause();
    button("Create local project")!.click();
    ensure(
      await until(
        () =>
          fixture.store.hostingHub.detail?.item.title ===
          "Offline release plan",
      ),
      "Local project creation failed without account",
    );
    ensure(
      fixture.http === 0 && fixture.credentials === 0,
      "Local creation accessed remote account or network",
    );
    button("Add task")!.click();
    await pause();
    enter(input("Draft title"), "Ship offline planner");
    await pause();
    const writeDocument = ipc.localProjectsWrite;
    ipc.localProjectsWrite = async () => { throw new Error("Synthetic save failure"); };
    button("Create task")!.click();
    await saved();
    ensure(input("Draft title").value === "Ship offline planner" && !!host.querySelector(".project-composer [role=alert]"), "Failed task save lost input or inline error");
    ipc.localProjectsWrite = writeDocument;
    const writesBeforeTask = fixture.writes;
    button("Create task")!.click();
    button("Create task")?.click();
    await saved();
    ensure(fixture.writes === writesBeforeTask + 1, "Repeated submit created more than one task write");
    ensure(
      fixture.store.hostingHub.detail?.rows.length === 1,
      "Local task not created",
    );
    host.querySelector<HTMLButtonElement>(".project-agenda-task")?.click();
    if (!host.querySelector(".project-inspector")) {
      host
        .querySelector<HTMLButtonElement>(".project-agenda-row button")
        ?.click();
    }
    if (!host.querySelector(".project-inspector")) {
      const task = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
        (value) => value.textContent?.includes("Ship offline planner"),
      );
      task?.click();
    }
    ensure(
      await until(() => !!host.querySelector(".project-inspector")),
      "Local task inspector missing",
    );
    ensure(!host.querySelector(".project-comment-editor") && fixture.http === 0, "Local task showed or loaded a remote conversation");
    const priority =
      editor("local-priority").querySelector<HTMLSelectElement>("select")!;
    ensure(
      [...priority.options]
        .filter((option) => !option.disabled)
        .every((option) => !!option.value),
      "Required local priority could be cleared",
    );
    enter(priority, "local-high");
    await saved();
    const due = editor("local-due"),
      day = scheduleAddDays(localScheduleToday(), 2)!;
    enter(due.querySelector<HTMLInputElement>("input")!, day);
    await pause();
    due.querySelector<HTMLButtonElement>("button")!.click();
    await saved();
    const row = fixture.store.hostingHub.detail!.rows[0];
    ensure(
      row.values?.["local-due"] === day &&
        row.statuses["local-priority"] === "local-high",
      "Local dates or priority not persisted",
    );
    enter(
      editor("local-status").querySelector<HTMLSelectElement>("select")!,
      "local-done",
    );
    await saved();
    ensure(
      fixture.store.hostingHub.detail!.rows[0].state === "CLOSED",
      "Local status did not complete task",
    );
    button("Edit task")!.click();
    await pause();
    const title = [
      ...host.querySelectorAll<HTMLInputElement>(".project-inspector input"),
    ][0];
    enter(title, "Planner ready to ship");
    await pause();
    button(
      "Save changes",
      host.querySelector(".project-inspector")!,
    )!.click();
    await saved();
    const reopened = await fixture.reopen();
    ensure(
      (await reopened.detail(fixture.store.hostingHub.detail!.item.id)).rows[0]
        .title === "Planner ready to ship",
      "Local document did not survive model restart",
    );
    button("Board")!.click();
    await pause();
    const progressColumn = [...host.querySelectorAll<HTMLElement>(".project-column")].find((column) => column.querySelector("header strong")?.textContent === t("In progress"))!;
    progressColumn.querySelector<HTMLButtonElement>(".project-column-add")!.click();
    await pause();
    const quickTitle = progressColumn.querySelector<HTMLInputElement>(`input[aria-label="${t("Task title")}"]`)!;
    enter(quickTitle, "Capture work directly in progress");
    await pause();
    ipc.localProjectsWrite = async () => { throw new Error("Synthetic column save failure"); };
    progressColumn.querySelector<HTMLFormElement>("form")!.requestSubmit();
    await saved();
    ensure(quickTitle.value === "Capture work directly in progress" && !!progressColumn.querySelector("[role=alert]"), "Column save failure lost the title or inline error");
    ipc.localProjectsWrite = writeDocument;
    const beforeQuickAdd = fixture.writes;
    progressColumn.querySelector<HTMLFormElement>("form")!.requestSubmit();
    progressColumn.querySelector<HTMLFormElement>("form")!.requestSubmit();
    await saved();
    ensure(fixture.writes === beforeQuickAdd + 1 && fixture.store.hostingHub.detail!.rows.some((row) => row.title === "Capture work directly in progress" && row.statuses["local-status"] === "local-progress"), "Quick add lost its column or wrote twice");
    progressColumn.querySelector<HTMLButtonElement>(".project-column-add")!.click();
    await pause();
    progressColumn.querySelector<HTMLInputElement>("input")!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    await pause();
    ensure(!progressColumn.querySelector("form") && fixture.writes === beforeQuickAdd + 1, "Escape did not cancel column capture without writing");
    fixture.store.navigate("home");
    ensure(
      await until(
        () =>
          host.querySelector(".planning-metrics .completed strong")
            ?.textContent === "1",
      ),
      "Home did not load local tasks without account",
    );
    host
      .querySelector<HTMLButtonElement>(".planning-metrics .completed")!
      .click();
    await pause();
    ensure(
      !!host.querySelector(".planning-task"),
      "Completed local task absent from Home focus",
    );
    ensure(
      fixture.http === 0 && fixture.credentials === 0,
      "Local dashboard accessed account or network",
    );
    host.querySelector<HTMLButtonElement>(".planning-task")!.click();
    ensure(await until(()=>fixture.store.destination==="projects"&&host.querySelector(".project-inspector h2")?.textContent==="Planner ready to ship"),"Local Home task did not open its inspector");
    ensure(fixture.store.hostingHub.requestedProjectRowID===null,"Local Home task request was not consumed");
    fixture.store.navigate("home");ensure(await until(()=>!!host.querySelector(".planning-dashboard")),"Local Home did not reopen");
    button("Create a project")!.click();
    ensure(
      await until(() => !!host.querySelector(".project-create-chooser")),
      "Home creation request was not consumed on Projects mount",
    );
    button("Cancel", host.querySelector(".project-create-chooser")!)!.click();
    await pause();
    fixture.connect();
    button("New project")!.click();
    await pause();
    fixture.slowProbe();
    host.querySelectorAll<HTMLButtonElement>(".project-create-mode")[1].click();
    ensure(
      await until(
        () =>
          host
            .querySelector(".project-create-guidance")
            ?.textContent?.includes(t("Checking…")) === true,
      ),
      `Creation capability loading state missing: ${host.textContent}`,
    );
    ensure(
      button("Review and create")!.disabled,
      "Remote creation enabled during pending access probe",
    );
    const account = host.querySelector<HTMLSelectElement>(
      `select[aria-label="${t("Project creation account")}"]`,
    )!;
    enter(account, "fixture-second");
    ensure(
      await until(
        () =>
          host
            .querySelector(".project-create-guidance")
            ?.textContent?.includes("GitHub Pro") === true,
      ),
      "Second account plan not reported",
    );
    fixture.releaseProbe();
    await pause(80);
    ensure(
      host
        .querySelector(".project-create-guidance")
        ?.textContent?.includes("GitHub Pro") === true &&
        !host
          .querySelector(".project-create-guidance")
          ?.textContent?.includes("@planner"),
      "Late capability response replaced new account context",
    );
    enter(input("Project name"), "Review only project");
    await pause();
    ensure(
      !button("Review and create")!.disabled,
      "Unconfirmed permission incorrectly gated eligible paid or free account",
    );
    button("Review and create")!.click();
    await pause();
    ensure(
      host
        .querySelector(".project-create-review")
        ?.textContent?.includes(t("Private project")) === true,
      "Private visibility absent from final review",
    );
    button("Cancel", host.querySelector(".project-create-review")!)!.click();
    await pause();
    enter(
      host.querySelector<HTMLSelectElement>(
        `select[aria-label="${t("Project creation account")}"]`,
      )!,
      "fixture-planner",
    );
    ensure(
      await until(
        () =>
          host
            .querySelector(".project-create-guidance")
            ?.textContent?.includes("GitHub Free") === true &&
          !button("Review and create")?.disabled,
      ),
      "GitHub Free was incorrectly gated from project creation",
    );
    host.querySelectorAll<HTMLButtonElement>(".project-create-mode")[2].click();
    await pause();
    ensure(
      await until(() => !button("Review and create")?.disabled),
      "Public Free-eligible mode unavailable",
    );
    button("Review and create")!.click();
    await pause();
    ensure(
      host
        .querySelector(".project-create-review")
        ?.textContent?.includes(t("Public project")) === true,
      "Public visibility absent from final review",
    );
    button("Cancel", host.querySelector(".project-create-review")!)!.click();
    await pause();
    button("Cancel", host.querySelector(".project-create-chooser")!)!.click();
    ensure(
      fixture.remoteWrites === 0,
      "Cancelled creation sent a remote mutation",
    );
    await pause();
    button("New project")!.click();
    await pause();
    enter(input("Project name"), "Uncertain test creation");
    await pause();
    ensure(
      await until(
        () =>
          !!button("Review and create") &&
          !button("Review and create")!.disabled,
      ),
      "Probe not ready for uncertain creation test",
    );
    button("Review and create")!.click();
    await pause();
    button("Confirm", host.querySelector(".project-create-review")!)!.click();
    ensure(
      await until(() => fixture.store.hostingHub.uncertainWrite),
      "Uncertain create response did not lock writes",
    );
    button("Cancel", host.querySelector(".project-create-review")!)!.click();
    await pause();
    button("Cancel", host.querySelector(".project-create-chooser")!)!.click();
    await pause();
    button("New project")!.click();
    await pause();
    enter(input("Project name"), "Do not duplicate");
    await pause();
    ensure(
      button("Review and create")!.disabled && !!button("Refresh projects"),
      "Closing creation lost uncertain-write recovery",
    );
    button("Refresh projects")!.click();
    ensure(
      await until(() => !button("Review and create")?.disabled),
      "Exhaustive refresh did not reconcile creation lock",
    );
    button("Cancel", host.querySelector(".project-create-chooser")!)!.click();
    ensure(
      fixture.remoteWrites === 1,
      "Uncertain test repeated its simulated creation mutation",
    );
    await fixture.store.hostingHub.selectProjectSource("local");
    await fixture.store.hostingHub.select(localProjects.projects[0]);
    await pause();
    const detail = fixture.store.hostingHub.detail!;
    await localProjects.removeItem(detail, detail.rows[0]);
    await fixture.store.hostingHub.select(detail.item);
    ensure(
      fixture.store.hostingHub.detail?.rows.length === detail.rows.length - 1 && !fixture.store.hostingHub.detail.rows.some((row) => row.id === detail.rows[0].id),
      "Local task delete did not persist",
    );
    return [
      true,
      "Created a local project without credentials/network; column capture preserves status + failure/duplicate-submit/Escape guards + retained failed input + duplicate-submit guard + single-submit task create/edit/status/priority/dates, durable model reload, local Home and one-shot creation handoff; pending/stale capability guards and private/public review cancellation produced zero remote writes; one synthetic lost creation response stayed locked across close/reopen until exhaustive reconciliation.",
    ];
  } catch (error) {
    return [
      false,
      String(error instanceof Error ? (error.stack ?? error.message) : error),
    ];
  } finally {
    root.unmount();
    host.remove();
    fixture.releaseProbe();
    fixture.restore();
  }
}
