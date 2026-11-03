import { createRoot } from "react-dom/client";
import {
  planningFixture,
  PlanningFixtureShell,
} from "../src/app/lib/project-planning-fixture";
import { loadLanguage } from "../src/shared/i18n";
import "../src/app/styles/global.css";
const params = new URLSearchParams(location.search);
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const fixture = planningFixture({ organization: params.has("organization"), complete: params.has("complete") });
await fixture.load();
if (params.has("project")) fixture.store.navigate("projects");
createRoot(document.getElementById("root")!).render(
  <div
    style={{
      padding: 24,
      maxWidth: params.has("width") ? Number(params.get("width")) : 1400,
      margin: "0 auto",
    }}
  >
    <PlanningFixtureShell fixture={fixture} />
  </div>,
);
if (params.get("view"))
  setTimeout(
    () =>
      [
        ...document.querySelectorAll<HTMLButtonElement>(
          ".planning-viewbar>div button",
        ),
      ]
        .find(
          (button) =>
            button.textContent?.trim() ===
            (params.get("view") === "week"
              ? params.get("lang") === "ko"
                ? "주"
                : "Week"
              : params.get("lang") === "ko"
                ? "프로젝트"
                : "Projects"),
        )
        ?.click(),
    200,
  );
if (params.has("selftest") || params.has("complete-selftest")) {
  const { projectPlanningSelfTest, projectItemCompletenessSelfTest } = await import(
    "../src/app/lib/project-planning-selftest"
  );
  const result = await (params.has("complete-selftest") ? projectItemCompletenessSelfTest() : projectPlanningSelfTest());
  const output = document.createElement("pre");
  output.id = "planning-selftest-result";
  output.dataset.passed = String(result[0]);
  output.textContent = result[1];
  document.body.append(output);
}
