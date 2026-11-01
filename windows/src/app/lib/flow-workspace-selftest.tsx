import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { flowEngine, flowStoreFor } from "@/entities/flow";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { FlowPanel } from "@/widgets/sidebar";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 60));

/** Exercises the actual graph, engine-backed YAML editor and saved run history. */
export async function flowWorkspaceSelfTest(repo: string, runId: string): Promise<[boolean, string]> {
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-20000px", width: "1200px", height: "800px", display: "flex" });
  document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  store.path = repo;
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const until = async (predicate: () => boolean, timeout = 15000) => { const end = Date.now() + timeout; while (Date.now() < end) { if (predicate()) return true; await pause(); } return false; };
  const click = async (label: string) => {
    const find = () => [...host.querySelectorAll<HTMLButtonElement>("button")].find((entry) => entry.textContent?.trim() === t(label) || entry.getAttribute("aria-label") === t(label));
    check(await until(() => !!find() && !find()!.disabled), `Missing enabled button: ${label}`);
    find()!.click(); await pause();
  };
  const input = (element: HTMLTextAreaElement, value: string) => { Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(element, value); element.dispatchEvent(new Event("input", { bubbles: true })); };
  const originalRender = flowEngine.renderDesign;
  try {
    root.render(<FlowPanel store={store} />);
    check(await until(() => host.querySelectorAll("[data-flow-node]").length === 2), "Dependency graph did not render both script steps");
    check(host.querySelectorAll(".flow-edges > path").length === 1, "Dependency connector missing");
    host.querySelector<HTMLButtonElement>('[data-flow-node="after"]')!.click(); await pause();
    check(host.querySelector(".flow-inspector")?.textContent?.includes("echo done"), "Selected node script was not shown");
    await click("Run history");
    check(host.querySelector(`[data-flow-run="${runId}"]`), "Saved run missing from history");
    host.querySelector<HTMLButtonElement>(`[data-flow-run="${runId}"]`)!.click();
    check(await until(() => !!host.querySelector(".flow-run-graph [data-flow-node]")), "Saved run dependency graph missing");
    await click("Done");
    await click("Configure scripts");
    check(await until(() => !!host.querySelector("[data-flow-designer]")), "Visual module editor did not load by default");
    const canvas = host.querySelector<HTMLElement>(".flow-designer")!;
    const scale = () => Number.parseInt(canvas.querySelector(".flow-zoom")?.textContent ?? "0");
    const beforeZoom = scale();
    canvas.querySelector<HTMLButtonElement>(`button[aria-label="${t("Zoom in")}"]`)!.click(); await pause();
    check(scale() > beforeZoom, "Diagram zoom did not change the visible scale");
    const first = canvas.querySelector<HTMLButtonElement>("[data-flow-node]")!;
    const beforePosition = first.style.left;
    first.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", altKey: true, bubbles: true })); await pause();
    check(first.style.left !== beforePosition, "Module arrangement did not move the card");
    await click("Add module");
    host.querySelector<HTMLButtonElement>('[data-flow-add-block="cmd"]')!.click(); await pause();
    check(host.querySelectorAll(".flow-designer [data-flow-node]").length === 3, "Adding a module did not update the diagram");
    input(host.querySelector<HTMLTextAreaElement>('[data-flow-module-form="script"] textarea[aria-label="run"]')!, "echo designer-added"); await pause();
    const dependency = [...host.querySelectorAll<HTMLLabelElement>(".flow-dependencies label")].find((label) => label.textContent?.trim() === "after")?.querySelector<HTMLInputElement>("input");
    check(dependency && !dependency.disabled, "Dependency form did not offer an earlier module");
    dependency!.click(); await pause();
    flowEngine.renderDesign = async () => ({ schemaVersion: 1, yaml: "", formattingChanged: true, diagnostics: [{ severity: "error", code: "NUMERIC_PRECISION", message: "Keep the current draft" }] });
    await click("Advanced YAML");
    check(await until(() => !!host.querySelector(".flow-config-error")), "Render diagnostic was not shown");
    check(host.querySelector("[data-flow-designer]") && !host.querySelector(".flow-config-editor"), "Rejected rendering replaced the source editor");
    flowEngine.renderDesign = originalRender;
    await click("Advanced YAML");
    check(await until(() => !!host.querySelector(".flow-config-editor")), "Advanced YAML did not load");
    const visualYaml = host.querySelector<HTMLTextAreaElement>(".flow-config-editor")!.value;
    check(visualYaml.includes("designer-added") && visualYaml.includes("after"), "Visual input/dependency edits did not reach the complete YAML document");
    const path = joinPath(repo, ".gitch/flow.yml"), original = await ipc.readText(path);
    check(original, "Flow fixture is missing");
    input(host.querySelector<HTMLTextAreaElement>(".flow-config-editor")!, "version: 99\nflows: {}\n"); await pause();
    await click("Validate and save");
    check(await until(() => !!host.querySelector(".flow-config-error")), "Invalid YAML was accepted");
    check(await ipc.readText(path) === original, "Rejected configuration was not restored");
    input(host.querySelector<HTMLTextAreaElement>(".flow-config-editor")!, visualYaml + "\n# Edited in the visual flow workspace.\n"); await pause();
    await click("Validate and save");
    check(await until(() => !host.querySelector(".flow-config-editor")), "Valid YAML was not saved");
    check((await ipc.readText(path))?.includes("Edited in the visual flow workspace"), "Saved YAML contents missing");
    check(flowStoreFor(repo).list?.trusted === false, "Editing did not invalidate command trust");
    await click("Connected CI");
    check(host.querySelector("[data-flow-connected-ci]"), "Connected CI tab did not render");
    const importedSource = "version: 1\nflows:\n  imported-smoke:\n    nodes:\n      hello: {run: echo imported-preview}\n";
    const transfer = new DataTransfer();
    transfer.items.add(new File([importedSource], "imported-workflow.yml", { type: "application/yaml" }));
    host.querySelector(".flow-drop-surface")!.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: transfer }));
    check(await until(() => !!host.querySelector("[data-flow-import-preview]")), "Dropped YAML did not open an interpreted preview");
    check(!(await ipc.exists(joinPath(repo, ".gitch/flows/imported-workflow.yml"))), "Import preview wrote a file before save");
    await click("Use imported modules");
    check(await until(() => !!host.querySelector('[data-flow-module-form="hello"]')), "Imported modules did not open in the visual editor");
    await click("Validate and save");
    check(await until(() => !host.querySelector(".flow-config")), "Reviewed imported flow was not saved");
    check(await ipc.readText(joinPath(repo, ".gitch/flows/imported-workflow.yml")) === importedSource, "Imported YAML was changed unexpectedly");
    return [true, "Graph zoom/arrangement, schema module/dependency editing, render-error preservation, source validation/rollback, Connected CI and reviewed file-drop import checked"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { flowEngine.renderDesign = originalRender; root.unmount(); host.remove(); }
}
