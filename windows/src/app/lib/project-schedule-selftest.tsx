import { createRoot } from "react-dom/client";
import {
  accounts,
  localScheduleToday,
  scheduleAddDays,
  scheduleWeekDays,
} from "@/entities/hosting";
import type { RepoTarget } from "@/entities/git";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { HostingHubPanel } from "@/widgets/hosting-hub";
const pause = (ms = 25) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));
/** Real project UI with in-memory transport; no account, Git, or remote write is performed. */
export async function projectScheduleSelfTest(): Promise<[boolean, string]> {
  const original = {
      http: ipc.http,
      token: accounts.token,
      accounts: accounts.accounts,
    },
    host = document.createElement("div");
  host.hidden = true;
  document.body.append(host);
  const root = createRoot(host),
    writes: { field: string; value: string }[] = [],
    today = localScheduleToday(),
    tomorrow = scheduleWeekDays(today).includes(scheduleAddDays(today, 1)!)
      ? scheduleAddDays(today, 1)!
      : scheduleAddDays(today, -1)!,
    start = scheduleAddDays(today, -3)!,
    due = today;
  let dates: Record<string, string> = { START: start, DUE: due },
    status = "TODO",
    failDue = false;
  const source = {
    path: "C:/schedule-selftest",
    target: {
      provider: "github",
      host: "github.com",
      path: "team/repo",
      remote: "origin",
    } as RepoTarget,
    get hostingAccount() {
      return accounts.accounts[0] ?? null;
    },
  };
  const button = (label: string) =>
      [...host.querySelectorAll<HTMLButtonElement>("button")].find(
        (value) => value.textContent?.trim() === t(label) || (label === "Confirm" && value.matches(".project-review-sheet footer > button:last-child")),
      ),
    enter = (element: HTMLInputElement | HTMLSelectElement, value: string) => {
      Object.getOwnPropertyDescriptor(
        element instanceof HTMLSelectElement
          ? HTMLSelectElement.prototype
          : HTMLInputElement.prototype,
        "value",
      )!.set!.call(element, value);
      element.dispatchEvent(
        new Event(element instanceof HTMLSelectElement ? "change" : "input", {
          bubbles: true,
        }),
      );
    },
    field = (label: string) =>
      host.querySelector<HTMLSelectElement>(
        `select[aria-label="${t(label)}"]`,
      )!,
    ensure = (condition: boolean, message: string) => {
      if (!condition) throw new Error(message);
    },
    until = async (test: () => boolean) => {
      for (let tries = 0; tries < 140; tries++) {
        if (test()) return true;
        await pause();
      }
      return false;
    },
    node = (id = "PROJECT") => ({
      id,
      title: id === "PROJECT" ? "Release plan" : "Other project",
      url: `https://github.com/orgs/team/projects/${id === "PROJECT" ? 1 : 2}`,
      fields: {
        nodes: [
          { id: "START", name: "Start date", dataType: "DATE" },
          { id: "DUE", name: "Due date", dataType: "DATE" },
          {
            id: "STATUS",
            name: "Status",
            options: [
              { id: "DONE", name: "Shipped" },
              { id: "TODO", name: "Ready" },
            ],
          },
        ],
        pageInfo: { hasNextPage: false },
      },
      items: {
        nodes: [
          {
            id: "ITEM",
            isArchived: false,
            content: {
              __typename: "Issue",
              id: "ISSUE",
              number: 1,
              title: "Build a calmer release",
              body: "Plan the work",
              url: "https://github.com/team/repo/issues/1",
              repository: { nameWithOwner: "team/repo" },
              assignees: { nodes: [{ login: "teammate" }] },
            },
            fieldValues: {
              nodes: [
                ...Object.entries(dates).map(([id, date]) => ({
                  date,
                  field: { id },
                })),
                { optionId: status, field: { id: "STATUS" } },
              ],
              pageInfo: { hasNextPage: false },
            },
          },
        ],
        pageInfo: { hasNextPage: false },
      },
    });
  try {
    accounts.accounts = [
      {
        id: "schedule-selftest",
        provider: "github",
        server: "https://github.com",
        username: "planner",
        name: null,
        avatarURL: null,
      },
    ];
    accounts.token = async () => "fixture-only";
    ipc.http = async (_method, _url, _headers, body) => {
      const payload = JSON.parse(body ?? "{}") as {
          query?: string;
          variables?: {
            id?: string;
            input?: {
              fieldId?: string;
              value?: { date?: string; singleSelectOptionId?: string };
            };
          };
        },
        query = payload.query ?? "",
        id = payload.variables?.id;
      let value: unknown;
      if (query.includes("mutation")) {
        const input = payload.variables?.input,
          fieldID = input?.fieldId ?? "",
          value =
            input?.value?.date ?? input?.value?.singleSelectOptionId ?? "";
        writes.push({ field: fieldID, value });
        if (failDue && fieldID === "DUE")
          return {
            status: 500,
            body: '{"message":"Temporary fixture failure"}',
          };
        if (fieldID === "STATUS") status = value;
        else dates[fieldID] = value;
        return {
          status: 200,
          body: JSON.stringify({
            data: {
              updateProjectV2ItemFieldValue: { projectV2Item: { id: "ITEM" } },
            },
          }),
        };
      }
      if (query.includes("views(first"))
        value = {
          node: {
            id: "PROJECT",
            views: { nodes: [], pageInfo: { hasNextPage: false } },
          },
        };
      else if (id === "ITEM")
        value = {
          node: {
            id: "ITEM",
            isArchived: false,
            project: { id: "PROJECT" },
            fieldValues: {
              nodes: Object.entries(dates).map(([id, date]) => ({
                date,
                field: { id },
              })),
              pageInfo: { hasNextPage: false },
            },
          },
        };
      else if (query.includes("node(id:")) value = { node: node(id) };
      else
        value = {
          repository: {
            owner: {
              projectsV2: {
                nodes: [
                  {
                    id: "PROJECT",
                    number: 1,
                    title: "Release plan",
                    url: "https://github.com/orgs/team/projects/1",
                  },
                  {
                    id: "OTHER",
                    number: 2,
                    title: "Other project",
                    url: "https://github.com/orgs/team/projects/2",
                  },
                ],
                pageInfo: { hasNextPage: false },
              },
            },
          },
        };
      return { status: 200, body: JSON.stringify({ data: value }) };
    };
    root.render(<HostingHubPanel store={source} section="projects" />);
    ensure(
      await until(() => !!host.querySelector(".project-overview")),
      "Default schedule overview missing",
    );
    ensure(
      host.querySelectorAll(".project-schedule-metrics>button").length === 5,
      "Schedule metrics missing",
    );
    ensure(
      host.querySelector<HTMLButtonElement>(".project-complete-task")!.disabled,
      "Completion guessed the first or last status option",
    );
    button("Board")!.click();
    await pause();
    button("Select items")!.click();
    await pause();
    host.querySelector<HTMLButtonElement>(".project-card")!.click();
    await pause();
    ensure(
      !!host.querySelector(".project-bulk-actions"),
      "Board selection did not start",
    );
    button("Calendar")!.click();
    await pause();
    ensure(
      !host.querySelector(".project-bulk-actions"),
      "Calendar kept stale bulk selection",
    );
    button("Overview")!.click();
    await pause();
    field("Complete tasks with").value = "";
    enter(field("Complete tasks with"), "DONE");
    await pause();
    ensure(writes.length === 0, "Setting completion mapping wrote to the server");
    button("Calendar")!.click();
    await pause();
    ensure(
      host.querySelectorAll(".project-calendar-day").length === 42,
      "Month grid does not cover six weeks",
    );
    button("Week")!.click();
    await pause();
    ensure(
      host.querySelectorAll(".project-calendar-day").length === 7,
      "Week grid is not seven days",
    );
    button("Today")!.click();
    await pause();
    const drag = () => {
      const data = new DataTransfer();
      host
        .querySelector<HTMLButtonElement>(".project-calendar-event")!
        .dispatchEvent(
          new DragEvent("dragstart", { dataTransfer: data, bubbles: true }),
        );
      host
        .querySelector<HTMLElement>(`[data-day="${tomorrow}"]`)!
        .dispatchEvent(
          new DragEvent("drop", {
            dataTransfer: data,
            bubbles: true,
            cancelable: true,
          }),
        );
    };
    drag();
    await pause();
    ensure(
      writes.length === 0 && !!button("Confirm"),
      "Drop mutated before confirmation",
    );
    button("Cancel")!.click();
    await pause();
    ensure(writes.length === 0, "Cancelled reschedule changed dates");
    drag();
    await pause();
    button("Confirm")!.click();
    ensure(
      await until(() => writes.length === 2 && !button("Confirm")),
      "Confirmed reschedule did not write both date fields",
    );
    ensure(
      dates.DUE === tomorrow &&
        dates.START === scheduleAddDays(start, tomorrow > today ? 1 : -1),
      "Reschedule did not preserve duration",
    );
    const beforeStale = writes.length;
    drag();
    await pause();
    [...host.querySelectorAll<HTMLButtonElement>(".hub-item")]
      .find((value) => value.textContent?.includes("Other project"))!
      .click();
    ensure(
      await until(
        () =>
          host.querySelector(".project-hero h1")?.textContent ===
          "Other project",
      ),
      "Project switch failed",
    );
    ensure(
      !button("Confirm") && writes.length === beforeStale,
      "Stale project confirmation survived navigation",
    );
    [...host.querySelectorAll<HTMLButtonElement>(".hub-item")]
      .find((value) => value.textContent?.includes("Release plan"))!
      .click();
    ensure(
      await until(
        () =>
          host.querySelector(".project-hero h1")?.textContent ===
          "Release plan",
      ),
      "Project did not restore",
    );
    button("Calendar")!.click();
    await pause();
    const keyboard = host.querySelector<HTMLDetailsElement>(
      ".project-calendar-keyboard",
    )!;
    keyboard.open = true;
    enter(field("Task to schedule"), "ITEM");
    enter(
      host.querySelector<HTMLInputElement>(
        `input[aria-label="${t("New task date")}"]`,
      )!,
      scheduleAddDays(today, 2)!,
    );
    await pause();
    failDue = true;
    button("Review new dates")!.click();
    await pause();
    button("Confirm")!.click();
    ensure(
      await until(
        () =>
          host.textContent?.includes(
            t(
              "The schedule may have changed. Refresh the project before scheduling again.",
            ),
          ) === true,
      ),
      "Partial date failure did not require refresh",
    );
    ensure(
      host.querySelector<HTMLButtonElement>(".project-calendar-event")!
        .draggable === false,
      "Uncertain schedule writes did not lock drag actions",
    );
    failDue = false;
    button("Retry")!.click();
    ensure(
      await until(
        () =>
          host.querySelector<HTMLButtonElement>(".project-calendar-event")
            ?.draggable === true,
      ),
      "Successful refresh did not restore scheduling",
    );
    button("Overview")!.click();
    await pause();
    const beforeComplete = writes.length;
    host.querySelector<HTMLButtonElement>(".project-complete-task")!.click();
    ensure(
      await until(() => writes.length === beforeComplete + 1 && !host.querySelector(".hub-confirm")),
      "Completion did not update once without an extra review",
    );
    ensure(
      writes.at(-1)?.field === "STATUS" && writes.at(-1)?.value === "DONE",
      "Completion did not use the configured status option",
    );
    return [
      true,
      "Overview metrics + single-submit completion + explicit completion mapping + month/week + drag confirmation/cancel + duration preservation + stale project guard + partial-write refresh lock + keyboard scheduling",
    ];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally {
    root.unmount();
    host.remove();
    ipc.http = original.http;
    accounts.token = original.token;
    accounts.accounts = original.accounts;
    try {
      localStorage.removeItem(
        "gitrochi.project-schedule.v1:schedule-selftest:PROJECT",
      );
    } catch {
      /* Isolated fixture preferences only. */
    }
  }
}
