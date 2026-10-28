import { createRoot } from "react-dom/client";
import { RepoPage } from "@/pages/repo";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { laneFixture } from "./graph-lanes-selftest";

const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 120));

/** The real repository screen keeps its center and inspector state while the right panel is hidden. */
export async function inspectorVisibilitySelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, subscribe: settings.subscribe, version: settings.getVersion, run: ipc.run, http: ipc.http, write: ipc.writeText };
  const memory = new Map<string, unknown>([["avatarFetch", false], ["inspectorWidth", 410], ["recentRepositories", []]]);
  const listeners = new Set<() => void>(), unexpected: string[] = [];
  let version = 0;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:1440px;height:720px";
  document.body.append(host);
  let root = createRoot(host);
  const store = laneFixture(6), commit = store.entries[0].commit;
  store.destination = "repository";
  store.showTerminal = true;
  store.selection = { kind: "commit", sha: commit.id };
  store.detail = { sha: commit.id, parents: [], author: commit.author, email: commit.email, date: commit.date, committer: commit.author, committerEmail: commit.email, commitDate: commit.date, summary: "Keep the right panel's state", body: "A long description with a locally expanded view. ".repeat(30) };
  store.loadGlobalIdentity = async () => {};
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const panel = () => host.querySelector<HTMLElement>(".repository-screen > .inspector")!;
  const center = () => host.querySelector<HTMLElement>(".repository-screen > .center")!;
  const toggle = () => host.querySelector<HTMLButtonElement>(".toolbar button[aria-expanded]")!;
  const expanded = () => [...panel().querySelectorAll("button")].some((button) => button.textContent === t("Collapse"));
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); version++; listeners.forEach((listener) => listener()); };
    settings.subscribe = (listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
    settings.getVersion = () => version;
    ipc.run = async () => { unexpected.push("process"); throw new Error("Inspector fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Inspector fixture blocked network"); };
    ipc.writeText = async () => { unexpected.push("write"); throw new Error("Inspector fixture blocked write"); };
    root.render(<RepoPage store={store} openSettings={() => {}} />); await settle();
    const originalPanel = panel(), originalCenter = center(), graph = center().querySelector(".graph-scroll"), terminal = center().querySelector<HTMLElement>(".term-panel")!;
    const width = panel().getBoundingClientRect().width, centerWidth = center().getBoundingClientRect().width;
    ensure(width === 410 && terminal && graph, "The fixture needs the saved panel width, graph and terminal");
    [...panel().querySelectorAll("button")].find((button) => button.textContent === t("Show all"))!.click(); await settle();
    ensure(expanded(), "The inspector's local expansion state must be set before hiding it");
    ensure(toggle().getAttribute("aria-label") === t("Hide right panel") && toggle().dataset.tip?.includes("Ctrl+Alt+B"), "The close control must name the action and its shortcut");
    toggle().click(); await settle();
    ensure(panel().hidden && getComputedStyle(panel()).display === "none" && memory.get("inspectorCollapsed") === true, "Closing must hide the panel and save the choice");
    ensure(center().getBoundingClientRect().width >= centerWidth + width - 1 && terminal.getBoundingClientRect().width === center().getBoundingClientRect().width, "The graph and terminal must take the freed width");
    ensure(toggle().getAttribute("aria-label") === t("Show right panel") && toggle().getAttribute("aria-expanded") === "false", "A visible reopen button must remain in the toolbar");
    toggle().click(); await settle();
    ensure(!panel().hidden && panel().getBoundingClientRect().width === width && memory.get("inspectorWidth") === 410, "Reopening must restore the saved width");
    ensure(panel() === originalPanel && center() === originalCenter && center().querySelector(".graph-scroll") === graph && center().querySelector(".term-panel") === terminal && expanded(), "Hiding must preserve both columns' mounted views and local state");
    toggle().click(); await settle();
    root.unmount(); root = createRoot(host);
    root.render(<RepoPage store={store} openSettings={() => {}} />); await settle();
    ensure(panel().hidden && memory.get("inspectorWidth") === 410, "A new screen must restore the saved collapsed choice and width");
    toggle().click(); await settle();
    ensure(panel().getBoundingClientRect().width === 410, "A new screen must reopen at the previous width");
    ensure(unexpected.length === 0, `Panel toggles triggered external work: ${unexpected.join(", ")}`);
    return [true, "Close and reopen controls with a shortcut hint; graph and terminal use the freed width; saved visibility and width survive remounting; local inspector expansion and both columns stay mounted; no external work"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
    ipc.run = original.run; ipc.http = original.http; ipc.writeText = original.write;
  }
}
