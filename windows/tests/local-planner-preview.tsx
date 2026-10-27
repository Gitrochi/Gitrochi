import { createRoot } from "react-dom/client";
import { ipc } from "../src/shared/api";
import { loadLanguage } from "../src/shared/i18n";
import {
  localProjects,
  localScheduleToday,
  scheduleAddDays,
} from "../src/entities/hosting";
import {
  localPlannerFixture,
  LocalPlannerFixtureShell,
} from "../src/app/lib/local-planner-fixture";
import "../src/app/styles/global.css";
const params = new URLSearchParams(location.search);
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const fixture = localPlannerFixture();
ipc.openUrl = async () => {};
if (params.has("seed")) {
  const item = await localProjects.create(
    "Product launch",
    "A focused local workspace. Turn the next idea into a clear plan.",
  );
  let detail = await localProjects.detail(item.id);
  for (const [index, title] of [
    "Finalize the launch checklist",
    "Polish the onboarding experience",
    "Review the keyboard workflow",
    "Prepare release notes",
  ].slice(0, params.has("sparse") ? 1 : undefined).entries()) {
    detail = await localProjects.saveDraft(
      detail,
      title,
      "A clear next action for the release.",
    );
    if (!params.has("undated")) detail = await localProjects.updateField(
      detail,
      detail.rows[index],
      detail.fields.find((field) => field.id === "local-due")!,
      scheduleAddDays(localScheduleToday(), index - 1)!,
    );
  }
  await fixture.store.hostingHub.selectProjectSource("local");
  await fixture.store.hostingHub.select(item);
}
if (params.get("view") === "home") fixture.store.navigate("home");
createRoot(document.getElementById("root")!).render(
  <div
    style={{
      padding: 20,
      height: "100vh",
      overflow: "auto",
      maxWidth: params.has("width") ? Number(params.get("width")) : 1440,
      margin: "auto",
    }}
  >
    <LocalPlannerFixtureShell fixture={fixture} />
  </div>,
);
if (params.has("layout"))
  setTimeout(() => {
    document.querySelectorAll<HTMLButtonElement>(".project-view-switch button")[["overview", "calendar", "board", "list", "timeline"].indexOf(params.get("layout")!)]?.click();
  }, 200);
if (params.has("create"))
  setTimeout(
    () => fixture.store.hostingHub.requestProjectCreation("local"),
    200,
  );
if (params.has("selftest")) {
  const { localPlannerSelfTest } = await import(
    "../src/app/lib/local-planner-selftest"
  );
  const result = await localPlannerSelfTest();
  const output = document.createElement("pre");
  output.id = "local-planner-selftest-result";
  output.dataset.passed = String(result[0]);
  output.textContent = result[1];
  document.body.append(output);
}
