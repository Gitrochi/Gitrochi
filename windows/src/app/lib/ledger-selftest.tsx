import { createRoot } from "react-dom/client";
import { destinationEnabled, isWorkspaceDestination, restoredDestination } from "@/entities/git";
import type { LedgerNotice, LedgerSession, LedgerStore } from "@/entities/ledger";
import { RepoStore } from "@/entities/repo";
import { RepoPage } from "@/pages/repo";
import { ipc } from "@/shared/api";
import { env, settings, slash } from "@/shared/config";
import { t } from "@/shared/i18n";
import { SettingsDialog } from "@/widgets/settings";
import { openLedgerAt } from "./ledger-notifications";

const pause = (ms = 40) => new Promise<void>((resolve) => setTimeout(resolve, ms));
async function until(f: () => unknown, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (f()) return true;
    await pause(30);
  }
  return !!f();
}

/** Types into a React-controlled field */
function type(el: HTMLTextAreaElement | HTMLInputElement, text: string) {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(el, text);
  el.dispatchEvent(new Event("input", { bubbles: true }));
}
/** Picks an option of a React-controlled select */
function choose(el: HTMLSelectElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(el, value);
  el.dispatchEvent(new Event("change", { bubbles: true }));
}
const key = (target: EventTarget, key: string, mods: KeyboardEventInit = {}) => target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...mods }));
// A key press reaches the focused element, so window's capture listeners run first and its others last. Sent to
// window itself, they would run in the order they were added, and the app's own Ctrl+Z would come first.
const press = (k: string, mods: KeyboardEventInit = {}) => key(document.activeElement ?? document.body, k, mods);
const command = (k: string) => press(k, env.os === "macos" ? { metaKey: true } : { ctrlKey: true });
/** Enter leaves a number field, as in the app; a page without window focus gets no blur, so React then gets the focusout itself */
function leave(el: HTMLElement) {
  let left = false;
  const mark = () => { left = true; };
  el.addEventListener("focusout", mark);
  key(el, "Enter");
  el.removeEventListener("focusout", mark);
  if (!left) el.dispatchEvent(new FocusEvent("focusout", { bubbles: true }));
}

/**
 * The Ledger page on the demo backend: hidden without GITROCHI_LEDGER_PREVIEW, then opened from the page list without a
 * repository, and every view driven like a person would — an answer saved with Ctrl+Enter, triage keys with undo, the
 * waiting prompts, the quick launches, Board chips and bulk actions, the Graph, inspector operations with the drop confirmation, Ctrl+K,
 * the narrow sheet, Streams, the onboarding sheets with the claude-ledger import, and Settings › Ledger. Nothing leaves
 * the demo backend: the ledger core itself is blocked.
 */
export async function ledgerSelfTest(): Promise<[boolean, string]> {
  // loaded on demand, like the page itself, so the Ledger stays out of the start-up bundle
  const [{ DemoLedgerBackend, LedgerNotifier, LedgerStore, ledgerStore, ledgerTracking, verdictCounts, verdictLook }, { LedgerWorkspace }] = await Promise.all([import("@/entities/ledger"), import("@/widgets/ledger-workspace")]);
  const original = { preview: env.ledgerPreview, demo: env.ledgerDemo, get: settings.get, set: settings.set, subscribe: settings.subscribe, version: settings.getVersion, run: ipc.run, http: ipc.http, write: ipc.writeText, open: ipc.openUrl, core: ipc.ledgerCall, pick: ipc.ledgerPickDatabase };
  const memory = new Map<string, unknown>([["avatarFetch", false], ["recentRepositories", []]]);
  const listeners = new Set<() => void>(), unexpected: string[] = [], passed: string[] = [];
  // the agent center rewrites its hooks files when Track agents I start changes; nothing reaches the disk
  const hooksFiles: { path: string; content: string; tracking: boolean }[] = [];
  let version = 0;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:1400px;height:900px";
  document.body.append(host);
  let root = createRoot(host);
  const stores: LedgerStore[] = [];
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const $$ = <T extends Element = HTMLElement>(selector: string) => [...host.querySelectorAll<T>(selector)];
  const button = (scope: string, label: string) => $$<HTMLButtonElement>(`${scope} button`).find((b) => b.textContent?.trim() === t(label));
  try {
    settings.get = <T,>(k: string, fallback: T): T => (memory.has(k) ? memory.get(k) : fallback) as T;
    // like the app's settings: undefined removes a key, so reading it gives the default again
    settings.set = (k, value) => { if (value === undefined) memory.delete(k); else memory.set(k, value); version++; listeners.forEach((listener) => listener()); };
    settings.subscribe = (listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
    settings.getVersion = () => version;
    ipc.run = async () => { unexpected.push("process"); throw new Error("Ledger fixture blocked a process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Ledger fixture blocked the network"); };
    ipc.writeText = async (path, content) => {
      if (/\/agents\/hooks(-wsl)?\.json$/.test(slash(path))) { hooksFiles.push({ path, content, tracking: ledgerTracking.on }); return; }
      unexpected.push("write");
      throw new Error("Ledger fixture blocked a write");
    };
    ipc.openUrl = async () => { unexpected.push("url"); };
    ipc.ledgerCall = async () => { unexpected.push("ledger core"); throw new Error("Ledger fixture blocked the ledger core"); };
    ipc.ledgerPickDatabase = async () => "C:/fixture/claude-ledger/data/ledger.db";
    // the app's own Ledger runs on the demo too
    env.ledgerDemo = "1";

    // The switch: no Ledger without GITROCHI_LEDGER_PREVIEW; with it, a Tools page that opens without a repository
    env.ledgerPreview = null;
    ensure(!isWorkspaceDestination("ledger") && !destinationEnabled("ledger") && restoredDestination("ledger", false) === "home", "The Ledger must stay hidden without the preview switch");
    const app = new RepoStore();
    app.loadGlobalIdentity = async () => {};
    root.render(<RepoPage store={app} openSettings={() => {}} />);
    await until(() => $(".workspace-nav-item[data-page='flows']"));
    ensure(!$(".workspace-nav-item[data-page='ledger']"), "The page list showed the Ledger without the switch");
    env.ledgerPreview = "1";
    app.changed();
    ensure(await until(() => $(".workspace-nav-item[data-page='ledger']")), "The page list did not offer the Ledger with the switch on");
    const tools = $$<HTMLButtonElement>(".workspace-nav-item").map((b) => b.dataset.page);
    ensure(tools.indexOf("ledger") === tools.indexOf("flows") + 1 && !$<HTMLButtonElement>(".workspace-nav-item[data-page='ledger']")!.disabled, `The Ledger must follow Flows and open without a repository: ${tools.join(",")}`);
    $<HTMLButtonElement>(".workspace-nav-item[data-page='ledger']")!.click();
    ensure(await until(() => app.destination === "ledger" && $(".page-header h1")?.textContent === t("Ledger") && $(".ledger-page")), "The Ledger page did not open with its title");
    ensure(restoredDestination("ledger", false) === "ledger", "A remembered Ledger page must reopen without a repository");
    root.unmount();
    root = createRoot(host);
    passed.push("switch and page list");

    // A demo on a fixed clock, rendered on its own
    const clock = Date.UTC(2026, 9, 31, 9);
    const backend = new DemoLedgerBackend({ now: () => clock, repoPath: "C:/fixture/atlas" });
    const store = new LedgerStore(backend);
    stores.push(store);
    const find = (f: (s: LedgerSession) => boolean) => store.state!.sessions.find(f)!;
    // the repository's tab, as the quick launches use it
    const launches: unknown[][] = [];
    const launcher = { newTerminal: (...args: unknown[]) => void launches.push(["terminal", ...args]), startAgent: async (...args: unknown[]) => void launches.push(["agent", ...args]) };
    root.render(<LedgerWorkspace repoPath="C:/fixture/atlas" ledger={store} launcher={launcher} />);
    ensure(await until(() => $(".ledger-page[data-layout='wide'] [data-view='inbox'] .ledger-prompts")), "The Inbox did not open with its waiting prompts");
    ensure(store.project === "atlas" && $$(".ledger-prompt").length === 3, `The Inbox must filter to this repository's project: ${store.project} prompts=${$$(".ledger-prompt").length}`);
    ensure($$(".ledger-topbar").length === 1 && !$(".ledger-filters"), "A wide Ledger must have one compact filter bar and no second navigation column");
    ensure(getComputedStyle($(".ledger-tabs button.on")!).borderBottomWidth === "2px", "The active view must use an underline tab");

    // An answer saved in place with Ctrl+Enter
    const question = store.state!.questions.find((q) => q.state === "open" && store.session(q.sessionId)?.project === "atlas")!;
    const field = $<HTMLTextAreaElement>(`[data-item="q:${question.id}"] textarea`)!;
    field.focus();
    type(field, "Three times, then stop.");
    key(field, "Enter", { ctrlKey: true });
    ensure(await until(() => backend.world.questions.find((q) => q.id === question.id)?.answer === "Three times, then stop." && !$(`[data-item="q:${question.id}"]`)), "Ctrl+Enter did not save the answer");
    ensure(await until(() => document.activeElement === $(".ledger-inbox")), `Focus did not return to the Inbox after the answer was saved: ${document.activeElement?.tagName}`);
    passed.push("answer");

    // Triage keys: C confirms the active row, Ctrl+Z takes it back from the toast
    const toConfirm = find((s) => s.verdict === "confirm" && s.project === "atlas");
    $(`[data-item="s:${toConfirm.id}"]`)!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    await pause();
    press("c");
    ensure(await until(() => store.session(toConfirm.id)?.verdict === "expirable" && $(".ledger-toast button")), "C did not confirm the active session with an Undo toast");
    command("z");
    ensure(await until(() => store.session(toConfirm.id)?.verdict === "confirm"), "Ctrl+Z did not undo the confirmation");
    ensure(!document.querySelector(".modal-backdrop"), "Ctrl+Z also reached the repository's undo");
    press("ArrowDown");
    await pause();
    ensure($(".ledger-row.active"), "The arrow keys did not move through the Inbox");
    const toMerge = find((s) => s.verdict === "pending_merge" && s.project === "atlas");
    $(`[data-item="s:${toMerge.id}"]`)!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    await pause();
    press("m");
    ensure(await until(() => document.querySelector(".menu .menu-item")), "M did not open the version picker");
    press("Escape");
    ensure(await until(() => !document.querySelector(".menu")), "Escape did not close the version picker");
    passed.push("triage keys and undo");

    // Waiting prompts: hold one, allow the permission (whose dialog the terminal shows as well)
    const prompts = store.state!.pendingPrompts.filter((p) => p.state === "waiting" && store.session(p.sessionId)?.project === "atlas");
    const held = prompts.find((p) => p.kind === "stop_question")!, permission = prompts.find((p) => p.kind === "permission")!;
    ensure($(`[data-prompt="${permission.id}"]`)?.textContent?.includes(t("The agent's terminal shows this request too; an answer there counts as well.")) && !$(`[data-prompt="${held.id}"]`)?.textContent?.includes(t("The agent's terminal shows this request too; an answer there counts as well.")), "A permission request must say that the terminal asks too");
    ensure(/\d:\d\d/.test($(`[data-prompt="${held.id}"] [role="timer"]`)?.textContent ?? ""), `The countdown did not show the time left: ${$(`[data-prompt="${held.id}"] [role="timer"]`)?.textContent}`);
    button(`[data-prompt="${held.id}"]`, "Not this time")!.click();
    ensure(await until(() => !$(`[data-prompt="${held.id}"]`) && (backend.world.prompts.find((p) => p.id === held.id)?.answer as { hold?: boolean } | undefined)?.hold === true), "Not this time did not stop the automatic answer");
    button(`[data-prompt="${permission.id}"]`, "Allow")!.click();
    ensure(await until(() => !$(`[data-prompt="${permission.id}"]`) && backend.world.prompts.find((p) => p.id === permission.id)?.state === "answered"), "Allowing a prompt did not answer it");
    // A wait auto-continue left to the person says why, and only the agent's terminal can answer it
    const kept = { id: backend.world.nextPrompt++, sessionId: permission.sessionId, kind: "permission" as const, payload: { kind: "permission", question: "Bash: git push --force", tool: { name: "Bash", summary: "git push --force" }, hold: { code: "held", rule: "push", detail: "git push --force", message: "held by push" } }, createdAt: clock, deadline: 0, state: "waiting" as const };
    backend.world.prompts.push(kept);
    backend.world.rev++;
    await store.refresh(true);
    ensure(await until(() => $(`[data-prompt="${kept.id}"]`)), "A wait held for the person did not show");
    const keptText = $(`[data-prompt="${kept.id}"]`)!.textContent ?? "";
    ensure(keptText.includes(t("Auto-continue never answers this kind of request.")) && keptText.includes(t("Answer it in the agent's terminal.")), `A held wait must say why and where to answer it: ${keptText}`);
    ensure(!button(`[data-prompt="${kept.id}"]`, "Allow") && !button(`[data-prompt="${kept.id}"]`, "Deny") && !button(`[data-prompt="${kept.id}"]`, "Not this time"), "A held wait must offer no answer the agent would not get");
    button(`[data-prompt="${kept.id}"]`, "Answer in terminal")!.click();
    ensure(await until(() => $(".ledger-toast")?.textContent?.includes(t("The agent's terminal is not open in Gitrochi. Answer it where the agent runs."))), "Answer in terminal did not look for the agent's terminal");
    ensure(backend.world.prompts.find((p) => p.id === kept.id)?.state === "waiting", "Answer in terminal must leave a held wait to the terminal's answer");
    passed.push("waiting prompts");

    // Quick launches: the overview is off on the demo data, and Claude Code starts as Run agent does
    $<HTMLButtonElement>("[data-quick-launch]")!.click();
    ensure(await until(() => document.querySelector(".menu .menu-item")), "The quick launch menu did not open");
    const launchItem = (label: string) => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.textContent?.trim() === label);
    ensure(launchItem(t("Ledger overview"))?.classList.contains("disabled"), "The Ledger overview must be off on the demo data");
    launchItem("Claude Code")!.click();
    ensure(await until(() => launches.length > 0), "Claude Code did not start");
    ensure(JSON.stringify(launches) === JSON.stringify([["agent", "C:/fixture/atlas", "", null, "claude"]]), `Claude Code must start as Run agent does: ${JSON.stringify(launches)}`);
    passed.push("quick launches");

    // Compact filters: project, text and verdict quick-jumps at every width; counts live only in the menu.
    $<HTMLButtonElement>(".ledger-tabs [data-view='board']")!.click();
    ensure(await until(() => $(".ledger-board .ledger-table-row")), "The Board did not open");
    const counts = verdictCounts(store.state!.sessions, "atlas").filter((c) => c.count);
    const menuItem = (label: string) => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.querySelector(".label")?.textContent === label);
    $<HTMLButtonElement>(".ledger-verdict-menu")!.click();
    ensure(await until(() => menuItem(t("All verdicts"))), "The compact verdict filter did not open");
    const menuCounts = [...document.querySelectorAll(".menu .shortcut")].map((c) => Number(c.textContent));
    ensure(JSON.stringify(menuCounts) === JSON.stringify(counts.map((c) => c.count)) && !$$(".ledger-chip .count").length, `Verdict counts must appear once in the menu: ${menuCounts} vs ${counts.map((c) => c.count)}`);
    menuItem(t(verdictLook(counts[0].verdict).label))!.click();
    ensure(await until(() => store.verdicts.size === 1 && store.verdicts.has(counts[0].verdict) && $$(".ledger-table-row").length > 0 && $$<HTMLElement>(".ledger-table-row").every((r) => store.session(r.dataset.session)?.verdict === counts[0].verdict)), "A verdict menu item did not filter the Board");
    ensure($(".ledger-verdict-menu")?.getAttribute("aria-label") === `${t("Verdicts")}: ${t(verdictLook(counts[0].verdict).label)}`, "The verdict filter must announce its selected value");
    $<HTMLButtonElement>(".ledger-verdict-menu")!.click();
    ensure(await until(() => menuItem(t("All verdicts"))), "The verdict filter did not reopen");
    menuItem(t("All verdicts"))!.click();
    ensure(await until(() => store.verdicts.size === 0 && $$(".ledger-table-row").length > 2), "All verdicts did not clear the Board's verdict filter");
    const project = $<HTMLSelectElement>(".ledger-topbar select")!;
    choose(project, "all");
    ensure(await until(() => store.project === null && $$<HTMLElement>(".ledger-table-row").some((r) => store.session(r.dataset.session)?.project !== "atlas")), "The project menu did not show all projects");
    choose(project, "repository");
    ensure(await until(() => store.project === "atlas" && $$<HTMLElement>(".ledger-table-row").every((r) => store.session(r.dataset.session)?.project === "atlas")), "The project menu did not return to this repository");
    const text = $<HTMLInputElement>(".ledger-topbar input")!;
    const filtered = $<HTMLElement>(".ledger-table-row")!.dataset.session!;
    type(text, filtered);
    ensure(await until(() => $$(".ledger-table-row").length === 1 && $<HTMLElement>(".ledger-table-row")?.dataset.session === filtered), "The top filter did not narrow sessions by text");
    key(text, "Escape");
    ensure(await until(() => store.filterText === "" && $$(".ledger-table-row").length > 2), "Escape did not clear the top text filter");
    passed.push("compact project, verdict and text filters");

    // Board: one verdict, bulk archive undone as one
    const needs = $$<HTMLButtonElement>(".ledger-chip")[0];
    needs.click();
    ensure(await until(() => $$<HTMLElement>(".ledger-table-row").every((r) => store.session(r.dataset.session)?.verdict === counts[0].verdict)), "A chip did not filter the Board");
    needs.click();
    await until(() => $$(".ledger-table-row").length > 2);
    const picked = $$<HTMLElement>(".ledger-table-row").slice(0, 2);
    for (const row of picked) row.querySelector<HTMLInputElement>("input")!.click();
    ensure(await until(() => $(".ledger-bulk")), "Selecting rows did not show the bulk actions");
    button(".ledger-bulk", "Clean up")!.click();
    const ids = picked.map((r) => r.dataset.session!);
    ensure(await until(() => ids.every((id) => store.session(id)?.verdict === "archived")), "Bulk archive did not archive both sessions");
    $<HTMLButtonElement>(".ledger-toast button")!.click();
    ensure(await until(() => ids.every((id) => store.session(id)?.verdict !== "archived")), "Undo did not restore both sessions");
    store.setChecked([]);
    const launch = await store.backend.call("track", { project: "atlas", title: "Unreported launch", kind: "other", agentId: "agent-unreported", cwd: "C:/fixture/atlas" });
    await store.refresh(true);
    const unreported = $$(".ledger-board-bar label").find((label) => label.textContent?.trim() === t("Unreported"))?.querySelector<HTMLInputElement>("input");
    ensure(unreported, "The Board has no Unreported filter");
    unreported!.click();
    ensure(await until(() => {
      const rows = $$<HTMLElement>(".ledger-table-row");
      return rows.some((row) => row.dataset.session === launch.session.id) && rows.every((row) => store.session(row.dataset.session)?.lastAgentAt == null);
    }), "Unreported must find launches without an agent report");
    const launchRow = $<HTMLElement>(`.ledger-table-row[data-session='${launch.session.id}']`)!;
    launchRow.querySelector<HTMLInputElement>("input")!.click();
    ensure(await until(() => $(".ledger-bulk strong")?.textContent === t("{0} selected", 1)), "The new launch was not the only selected session");
    button(".ledger-bulk", "Mark closed")!.click();
    ensure(await until(() => store.session(launch.session.id)?.status === "closed"), "An unreported launch could not be closed");
    unreported!.click();
    passed.push("board chips, bulk actions and Unreported launches");

    // Graph: drawn and clickable
    $<HTMLButtonElement>(".ledger-tabs [data-view='graph']")!.click();
    ensure(await until(() => $$(".ledger-graph-canvas svg path").length > 5 && $(".ledger-graph-row")), "The Graph did not draw");
    const sessionRow = $$<HTMLElement>(".ledger-graph-row").find((r) => r.querySelector(".ledger-id"))!;
    sessionRow.click();
    ensure(await until(() => store.selectedId && $(".ledger-inspector-head")?.textContent?.includes(store.selectedId)), "Clicking a graph row did not open its session");
    passed.push("graph");

    // Inspector: close a session to decide, undo; drop asks once
    const decide = find((s) => s.verdict === "pending_merge" && s.project === "atlas");
    store.select(decide.id);
    ensure(await until(() => button(".ledger-actions", "Mark closed")), `The inspector did not offer Mark closed for a session to decide: ${decide.id} [${$(".ledger-actions")?.textContent}]`);
    button(".ledger-actions", "Mark closed")!.click();
    ensure(await until(() => store.session(decide.id)?.status === "closed" && store.session(decide.id)?.verdict === "expirable"), "Close did not close and confirm the session");
    $<HTMLButtonElement>(".ledger-toast button")!.click();
    ensure(await until(() => store.session(decide.id)?.verdict === "pending_merge"), "Undo did not reopen the decision");
    await until(() => store.busy === 0);
    button(".ledger-actions", "More")!.click();
    ensure(await until(() => [...document.querySelectorAll<HTMLElement>(".menu-item")].some((m) => m.textContent?.includes(t("Mark dropped…")))), "The More menu did not open");
    [...document.querySelectorAll<HTMLElement>(".menu-item")].find((m) => m.textContent?.includes(t("Mark dropped…")))!.click();
    ensure(await until(() => button(".modal", "Drop session")), "Dropping did not ask first");
    button(".modal", "Drop session")!.click();
    ensure(await until(() => store.session(decide.id)?.status === "dropped"), "Confirming the drop did not drop the session");
    passed.push("inspector operations");

    // Auto-continue per session: for agents Gitrochi started, never for the decision role, undone from the toast
    const limits = find((s) => s.title.startsWith("Rate limit") && !!s.links.agentId);
    store.select(limits.id);
    const autoBox = () => $<HTMLInputElement>(".ledger-auto-continue input[type='checkbox']");
    const policyOf = (id: string) => backend.world.sessions.find((s) => s.id === id)?.autoContinue;
    ensure(await until(() => store.selectedId === limits.id && autoBox()?.checked === true && !autoBox()!.disabled), "The inspector did not show the session's auto-continue switch on");
    autoBox()!.click();
    ensure(await until(() => policyOf(limits.id)?.enabled === false && $(".ledger-toast button")), "Turning auto-continue off did not reach the session with an Undo toast");
    $<HTMLButtonElement>(".ledger-toast button")!.click();
    ensure(await until(() => policyOf(limits.id)?.enabled === true), "Undo did not turn auto-continue back on");
    const waitField = () => $<HTMLInputElement>(`.ledger-auto-continue input[aria-label="${t("Wait")}"]`);
    ensure(await until(() => store.busy === 0 && waitField() && !waitField()!.disabled), "The wait field stayed disabled after the undo");
    const wait = waitField()!;
    wait.focus();
    type(wait, "45");
    leave(wait);
    ensure(await until(() => policyOf(limits.id)?.delaySec === 45), `Leaving the wait field did not save it: ${JSON.stringify(policyOf(limits.id))}`);
    const decision = find((s) => s.role === "decision" && !!s.links.agentId && s.project === "atlas");
    store.select(decision.id);
    ensure(await until(() => store.selectedId === decision.id && autoBox()?.disabled === true && $(".ledger-auto-continue")?.textContent?.includes(t("Sessions with the decision role never continue automatically."))), "A decision session must not offer auto-continue");
    passed.push("auto-continue per session");

    // Ctrl+K: search and open
    command("k");
    ensure(await until(() => $("input[role='combobox']")), "Ctrl+K did not open the search");
    const search = $<HTMLInputElement>("input[role='combobox']")!;
    type(search, "Retry policy");
    ensure(await until(() => $(".ledger-hit")), "The search found nothing");
    key(search, "Enter");
    ensure(await until(() => !$("input[role='combobox']") && store.session(store.selectedId)?.title.startsWith("Retry policy")), "Enter did not open the search result");
    passed.push("search");

    // Narrow: the same compact filters wrap and the inspector becomes a sheet.
    host.style.width = "620px";
    ensure(await until(() => $(".ledger-page[data-layout='narrow'] .ledger-topbar")), `A narrow page did not keep its filters: layout=${$(".ledger-page")?.dataset.layout} width=${$(".ledger-page")?.clientWidth} modal=${!!document.querySelector(".modal-backdrop")}`);
    ensure($$(".ledger-topbar").length === 1 && !$(".ledger-filters"), "A narrow Ledger must keep one filter bar without a navigation column");
    host.style.width = "360px";
    ensure(await until(() => $(".ledger-topbar")!.clientWidth <= 360), "The compact filter bar did not follow a small window");
    ensure($(".ledger-topbar")!.scrollWidth <= $(".ledger-topbar")!.clientWidth && $(".ledger-filter-input")!.getBoundingClientRect().top > $(".ledger-topbar select")!.getBoundingClientRect().top, "The filters must wrap inside a small window");
    host.style.width = "620px";
    $<HTMLButtonElement>(".ledger-tabs [data-view='board']")!.click();
    await until(() => $(".ledger-table-row"));
    $(".ledger-table-row")!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    ensure(await until(() => $(".modal .ledger-inspector")), "A narrow page did not open the inspector as a sheet");
    $<HTMLButtonElement>(`.modal .ledger-inspector-head button[aria-label="${t("Close")}"]`)!.click();
    ensure(await until(() => !$(".modal")), "The inspector sheet did not close");
    host.style.width = "1400px";
    passed.push("narrow layout");

    // Streams: the stream's three cycles
    $<HTMLButtonElement>(".ledger-tabs [data-view='streams']")!.click();
    ensure(await until(() => $$(".ledger-stream .ledger-cycle").length === 3), "Streams did not list the stream's cycles");
    passed.push("streams");

    // Onboarding on an empty ledger: Paste reports and Connect Claude Code
    root.unmount();
    root = createRoot(host);
    const empty = new LedgerStore(new DemoLedgerBackend({ now: () => clock, empty: true }));
    empty.setView("inbox");
    stores.push(empty);
    root.render(<LedgerWorkspace repoPath={null} ledger={empty} />);
    ensure(await until(() => $(".ledger-onboarding .card")), "An empty ledger did not show the onboarding");
    ensure($<HTMLButtonElement>("[data-quick-launch]")?.disabled && $(".ledger-quick-launch .hint")?.textContent === t("Open a repository to use its terminal"), "Without a repository the quick launch must be disabled with a visible reason");
    ensure($$(".ledger-onboarding .card").some((card) => card.textContent?.includes(t("Import from claude-ledger")) && card.querySelector("button")), "The onboarding did not offer the claude-ledger import");
    ensure($(".ledger-onboarding")?.textContent?.includes(t("No reports yet")), "The empty Ledger must explain that reports have not arrived");
    button(".ledger-onboarding", "Connect Claude Code")!.click();
    ensure(await until(() => button(".modal", "Test Ledger")), "Connect Claude Code did not open");
    ensure($$(".modal .ledger-code pre").some((pre) => pre.textContent?.includes("Use ledger_report to send a start report")) && $(".modal button[aria-label='" + t("Copy reporting instruction") + "']"), "Both the reporting instruction and its copy action must be available");
    ensure($(".modal")?.textContent?.includes(t("Checks this app's Ledger, not Claude Code's MCP configuration.")), "The probe must explain what it tests");
    const beforeProbe = empty.state!.rev;
    button(".modal", "Test Ledger")!.click();
    ensure(await until(() => $(".modal .card[role='status']")?.textContent?.includes(t("The Ledger responds."))), "Test Ledger did not answer");
    ensure(empty.state!.sessions.length === 0 && empty.state!.rev === beforeProbe && $(".ledger-onboarding"), "A successful Ledger probe must leave an empty Ledger empty");
    button(".modal", "Done")!.click();
    await until(() => !$(".modal"));
    button(".ledger-onboarding", "Paste reports")!.click();
    ensure(await until(() => $(".modal textarea")), "Paste reports did not open the import sheet");
    type($<HTMLTextAreaElement>(".modal textarea")!, '```ledger\n{"event":"start","session":"S1101-01","project":"atlas","title":"Imported in the self-test"}\n```\n```ledger\n{"event":"teleport"}\n```');
    $$<HTMLButtonElement>(".modal-footer button").at(-1)!.click();
    ensure(await until(() => $$(".ledger-result").length === 2 && empty.session("S1101-01")), "The import did not report each block and add the session");
    button(".modal-footer", "Close")!.click();
    await until(() => !$(".modal"));
    ensure(await until(() => $(".ledger-all-clear")?.textContent?.includes(t("Find progress in Board and Streams. Inbox only shows questions, reviews and decisions that need you."))), "An active reported session must explain why the Inbox has no actions");
    button(".ledger-all-clear", "View progress")!.click();
    ensure(await until(() => $(".ledger-board [data-session='S1101-01']")), "Open Board must show the active reported session");
    const streamsOnlyBackend = new DemoLedgerBackend({ now: () => clock, empty: true });
    await streamsOnlyBackend.call("import", { text: '```ledger\n{"event":"start","session":"S1101-stream","project":"atlas","kind":"implementation","title":"Stream progress"}\n```' });
    // The demo import stores the report; the core supplies this stream classification in native state.
    streamsOnlyBackend.world.sessions[0].stream = { line: "core" };
    const streamsOnly = new LedgerStore(streamsOnlyBackend);
    streamsOnly.setView("inbox");
    stores.push(streamsOnly);
    await streamsOnly.refresh(true);
    root.render(<LedgerWorkspace repoPath={null} ledger={streamsOnly} />);
    ensure(await until(() => $(".ledger-all-clear")), "A stream without questions should leave the Inbox clear");
    button(".ledger-all-clear", "View progress")!.click();
    ensure(await until(() => $(".ledger-stream[data-stream='S1101-stream']")), "View progress must open Streams when streams are the only sessions");
    root.render(<LedgerWorkspace repoPath={null} ledger={empty} />);
    await until(() => $(".ledger-board"));
    passed.push("onboarding, import and connect");

    // Import from claude-ledger: a dry run counts first, then the import adds the sessions
    $<HTMLButtonElement>(`.ledger-toolbar button[aria-label="${t("Paste reports")}"]`)!.click();
    ensure(await until(() => button(".modal", "Import from claude-ledger…")), "The import sheet did not offer the claude-ledger import");
    button(".modal", "Import from claude-ledger…")!.click();
    ensure(await until(() => button(".modal", "Choose a file")), "Import from claude-ledger did not open");
    ensure(button(".modal-footer", "Import")?.disabled, "Import from claude-ledger must wait for a file and its count");
    button(".modal", "Choose a file")!.click();
    ensure(await until(() => $(".modal .ledger-legacy-result") && !button(".modal-footer", "Import")?.disabled), "Choosing a claude-ledger file did not count what it would copy");
    ensure(!empty.session("S1021-01"), "The dry run must not import anything");
    button(".modal-footer", "Import")!.click();
    ensure(await until(() => empty.session("S1021-01") && button(".modal-footer", "Done")), "Import from claude-ledger did not add the sessions");
    button(".modal-footer", "Done")!.click();
    await until(() => !$(".modal"));
    passed.push("claude-ledger import");

    // Settings › Ledger: no tab without the preview; with it, the app's Ledger settings on the same backend
    root.unmount();
    root = createRoot(host);
    const labels = () => $$<HTMLButtonElement>(".modal .segmented button").map((b) => b.textContent?.trim());
    env.ledgerPreview = null;
    root.render(<SettingsDialog onClose={() => {}} initialTab="appearance" />);
    ensure(await until(() => labels().length > 0), "Settings did not open");
    ensure(!labels().includes(t("Ledger")), `Settings showed a Ledger tab without the preview: ${labels().join(", ")}`);
    root.unmount();
    root = createRoot(host);
    env.ledgerPreview = "1";
    memory.set("recentRepositories", ["C:/fixture/atlas"]);
    root.render(<SettingsDialog onClose={() => {}} initialTab="appearance" />);
    ensure(await until(() => labels().includes(t("Ledger"))), "Settings did not offer the Ledger tab with the preview");
    ensure(labels().indexOf(t("Ledger")) === labels().indexOf(t("Update")) - 1, `The Ledger tab must come before Update: ${labels().join(", ")}`);
    $$<HTMLButtonElement>(".modal .segmented button").find((b) => b.textContent?.trim() === t("Ledger"))!.click();
    const ledger = ledgerStore(null);
    ensure(ledger.backend.kind === "demo", "The app's Ledger did not use the demo with GITROCHI_LEDGER_DEMO");
    const staleField = () => $<HTMLInputElement>(`.ledger-settings input[aria-label="${t("Stale after")}"]`);
    ensure(await until(() => staleField()?.value === "72"), `Settings › Ledger did not show the stale hours: ${staleField()?.value}`);
    const stale = staleField()!;
    stale.focus();
    type(stale, "48");
    leave(stale);
    let saved = 0;
    await until(() => { void ledger.readSettings().then((x) => { saved = x.staleHours; }); return saved === 48; });
    ensure(saved === 48, `Leaving the stale hours field did not save them: ${saved}`);
    const kind = $<HTMLInputElement>(`.ledger-settings input[aria-label="${t("New kind")}"]`)!;
    kind.focus();
    type(kind, "spike");
    choose($<HTMLSelectElement>(`.ledger-settings select[aria-label="${t("Role")} · ${t("New kind")}"]`)!, "research");
    $<HTMLButtonElement>(`.ledger-settings button[aria-label="${t("Add kind")}"]`)!.click();
    ensure(await until(() => $<HTMLSelectElement>(`.ledger-kind[data-kind="spike"] select`)?.value === "research"), "Adding a kind did not list it with its role");
    $<HTMLButtonElement>(`.ledger-kind[data-kind="spike"] button[aria-label="${t("Remove")} · spike"]`)!.click();
    ensure(await until(() => !$(`.ledger-kind[data-kind="spike"]`)), "Removing a kind did not take it out");
    const source = $<HTMLSelectElement>(`.ledger-project select[aria-label="${t("Baselines from")} · atlas"]`)!;
    choose(source, "folder");
    ensure(await until(() => $(`.ledger-project[data-project="atlas"] input[aria-label="${t("Folder")} · atlas"]`)), "Choosing folder names did not ask for the folder");
    button(`.ledger-project[data-project="atlas"]`, "Scan now")!.click();
    ensure(await until(() => $(`.ledger-project[data-project="atlas"] .error-text`)), "Scanning a folder source without a folder did not say so");
    choose($<HTMLSelectElement>(`.ledger-project select[aria-label="${t("Baselines from")} · atlas"]`)!, "tags");
    ensure(await until(() => !$(`.ledger-project[data-project="atlas"] input[aria-label="${t("Folder")} · atlas"]`)), "Going back to Git tags kept the folder fields");
    // the project change saves first; the buttons wait for it
    ensure(await until(() => button(".ledger-settings", "Back up now") && !button(".ledger-settings", "Back up now")!.disabled), "Back up now stayed disabled after the project was saved");
    button(".ledger-settings", "Back up now")!.click();
    ensure(await until(() => $(".ledger-settings [role='status']")?.getAttribute("data-tip")?.startsWith("ledger/backups/ledger-")), `Back up now did not say where the copy went: ${$(".ledger-settings [role='status']")?.textContent}`);
    // Track agents I start, and auto-continue per repository in the ledger's setting
    const trackBoxes = () => $$<HTMLInputElement>(`.ledger-settings [data-ledger-section="tracking"] input[type="checkbox"]`);
    ensure(trackBoxes().length === 2 && !trackBoxes()[0].checked && trackBoxes()[1].disabled, "Track agents I start must start off, its tools switch waiting for it");
    trackBoxes()[0].click();
    ensure(await until(() => memory.get("ledgerTrackAgents") === true && ledgerTracking.on && !trackBoxes()[1].disabled), "Track agents I start did not turn on");
    trackBoxes()[1].click();
    ensure(await until(() => memory.get("ledgerAgentTools") === false && !trackBoxes()[1].checked), "Give them the Ledger tools did not turn off");
    trackBoxes()[1].click();
    ensure(await until(() => trackBoxes()[1].checked), "Give them the Ledger tools did not turn back on");
    const repository = () => $(`.ledger-repository[data-repository="C:/fixture/atlas"]`);
    ensure(await until(() => repository()), "Auto-continue did not list the repository");
    const policyFor = async () => ((await ledger.readSettings()).autoContinue.repositories as Record<string, { enabled: boolean; delaySec: number }> | undefined)?.["C:/fixture/atlas"];
    repository()!.querySelector<HTMLInputElement>("input[type='checkbox']")!.click();
    let policy: { enabled: boolean; delaySec: number } | undefined;
    await until(() => { void policyFor().then((p) => { policy = p; }); return policy?.enabled === true && policy.delaySec === 30; });
    ensure(policy?.enabled === true && policy.delaySec === 30, `Turning auto-continue on for the repository did not save it: ${JSON.stringify(policy)}`);
    await until(() => !button(".ledger-settings", "Back up now")!.disabled);
    const repoWait = repository()!.querySelector<HTMLInputElement>("input[type='number']")!;
    repoWait.focus();
    type(repoWait, "60");
    leave(repoWait);
    await until(() => { void policyFor().then((p) => { policy = p; }); return policy?.delaySec === 60; });
    ensure(policy?.enabled === true && policy.delaySec === 60, `The repository's wait did not save: ${JSON.stringify(policy)}`);
    trackBoxes()[0].click();
    ensure(await until(() => !memory.get("ledgerTrackAgents") && !ledgerTracking.on && trackBoxes()[1].disabled), "Track agents I start did not turn off again");
    // the hooks files name the ledger CLI only while tracking is on (when the app has the CLI at all)
    await until(() => hooksFiles.some((f) => !f.tracking), 1500);
    const cli = await ledgerTracking.cli();
    ensure(hooksFiles.every((f) => f.content.includes("gitrochi-ledger") === (f.tracking && !!cli)), `The hooks files did not follow Track agents I start: ${hooksFiles.map((f) => `${f.tracking}:${f.content.includes("gitrochi-ledger")}`).join(", ")}`);
    passed.push("track agents and auto-continue settings");
    // Notifications and the taskbar badge: both off until a person turns them on
    const noticeBoxes = () => $$<HTMLInputElement>(`.ledger-settings [data-ledger-section="notifications"] input[type="checkbox"]`);
    ensure(noticeBoxes().length === 2 && noticeBoxes().every((b) => !b.checked), "Notifications and the badge must start off");
    noticeBoxes()[0].click();
    ensure(await until(() => memory.get("ledgerNotifications") === true && noticeBoxes()[0].checked), "Turning notifications on did not save it");
    noticeBoxes()[0].click();
    noticeBoxes()[1].click();
    ensure(await until(() => memory.get("ledgerNotifications") === undefined && memory.get("ledgerBadge") === true && !noticeBoxes()[0].checked && noticeBoxes()[1].checked), "The notification switches did not follow the clicks");
    noticeBoxes()[1].click();
    ensure(await until(() => !noticeBoxes()[1].checked && !memory.has("ledgerBadge")), "The badge switch did not turn back off");
    passed.push("notification settings");
    button(".ledger-settings", "Connect Claude Code…")!.click();
    ensure(await until(() => button(".modal", "Test Ledger")), "Connect Claude Code… did not open from Settings");
    button(".modal", "Done")!.click();
    button(".ledger-settings", "Import from claude-ledger…")!.click();
    ensure(await until(() => button(".modal", "Choose a file")), "Import from claude-ledger… did not open from Settings");
    button(".modal-footer", "Close")!.click();
    passed.push("settings");

    // The notifier: nothing for what existed, each new item once with the time left, the overlay with the count, and a
    // click that opens the Ledger at the item
    let noticeClock = clock;
    const noticeDemo = new DemoLedgerBackend({ now: () => noticeClock, repoPath: "C:/fixture/atlas" });
    const sent: LedgerNotice[] = [], overlays: (number[] | null)[] = [];
    const notifier = new LedgerNotifier(() => noticeDemo, { notify: async (n) => { sent.push(n); }, badge: async (rgba) => { overlays.push(rgba); } });
    // off until a person turns them on: nothing is read
    await notifier.poll();
    ensure(!sent.length && !overlays.length, "The notifier must do nothing while both switches are off");
    memory.set("ledgerNotifications", true);
    memory.set("ledgerBadge", true);
    await notifier.poll();
    ensure(!sent.length, `Notifications must not announce what already existed: ${sent.map((n) => n.title).join(", ")}`);
    ensure(env.os !== "windows" || (overlays.length === 1 && overlays[0]?.length === 32 * 32 * 4), `The taskbar overlay did not get the count: ${overlays.map((o) => o?.length ?? "none").join(", ")}`);
    const asker = noticeDemo.world.sessions.find((s) => s.project === "atlas" && s.status === "active" && !s.archivedAt)!;
    noticeDemo.world.prompts.push({ id: noticeDemo.world.nextPrompt++, sessionId: asker.id, kind: "stop_question", payload: { question: "Shall I go on with the next step?", proposed: { type: "reply", text: "Yes, go on." } }, createdAt: noticeClock, deadline: noticeClock + 30_000, state: "waiting" });
    noticeDemo.world.rev++;
    await notifier.poll();
    const waitingNotice = sent.find((n) => n.title === t("{0} is waiting for you", asker.id));
    ensure(waitingNotice?.body.includes(t("Auto-answer in {0}", "0:30")), `A waiting prompt did not notify with the time left: ${sent.map((n) => `${n.title} / ${n.body}`).join(" | ")}`);
    noticeClock += 31_000;
    await notifier.poll();
    ensure(sent.some((n) => n.title === t("Answered automatically for {0}", asker.id)), "An automatic answer did not notify");
    const clickTab = new RepoStore();
    clickTab.loadGlobalIdentity = async () => {};
    const clickStore = new LedgerStore(noticeDemo);
    stores.push(clickStore);
    openLedgerAt(clickTab, clickStore, waitingNotice!.target);
    ensure(clickTab.destination === "ledger" && clickStore.selectedId === asker.id && clickStore.view === "inbox", `A click did not open the Ledger at the item: ${clickTab.destination} ${clickStore.selectedId} ${clickStore.view}`);
    memory.delete("ledgerNotifications");
    memory.delete("ledgerBadge");
    passed.push("notifications");

    ensure(!unexpected.length, `The Ledger reached outside the demo: ${unexpected.join(", ")}`);
    return [true, passed.join("; ")];
  } catch (error) {
    return [false, `${error instanceof Error ? error.message : String(error)} (passed: ${passed.join("; ")})`];
  } finally {
    root.unmount();
    host.remove();
    for (const s of stores) s.dispose();
    env.ledgerPreview = original.preview;
    env.ledgerDemo = original.demo;
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
    ipc.run = original.run; ipc.http = original.http; ipc.writeText = original.write; ipc.openUrl = original.open; ipc.ledgerCall = original.core; ipc.ledgerPickDatabase = original.pick;
  }
}
