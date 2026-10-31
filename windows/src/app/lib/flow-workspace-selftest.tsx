import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { flowStoreFor } from "@/entities/flow";
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
    check(await until(() => !!host.querySelector(".flow-config-editor")), "YAML editor did not load");
    const path = joinPath(repo, ".gitch/flow.yml"), original = await ipc.readText(path);
    check(original, "Flow fixture is missing");
    input(host.querySelector<HTMLTextAreaElement>(".flow-config-editor")!, "version: 99\nflows: {}\n"); await pause();
    await click("Validate and save");
    check(await until(() => !!host.querySelector(".flow-config-error")), "Invalid YAML was accepted");
    check(await ipc.readText(path) === original, "Rejected configuration was not restored");
    input(host.querySelector<HTMLTextAreaElement>(".flow-config-editor")!, original + "\n# Edited in the visual flow workspace.\n"); await pause();
    await click("Validate and save");
    check(await until(() => !host.querySelector(".flow-config-editor")), "Valid YAML was not saved");
    check((await ipc.readText(path))?.includes("Edited in the visual flow workspace"), "Saved YAML contents missing");
    check(flowStoreFor(repo).list?.trusted === false, "Editing did not invalidate command trust");
    return [true, "Dependency cards and edge, script inspection, saved-run graph, invalid YAML rollback and valid YAML save checked"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); }
}
