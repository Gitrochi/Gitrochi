import { createRoot } from "react-dom/client";
import { destinationEnabled, isWorkspaceDestination, restoredDestination } from "@/entities/git";
import type { LedgerSession, LedgerStore } from "@/entities/ledger";
import { RepoStore } from "@/entities/repo";
import { RepoPage } from "@/pages/repo";
import { ipc } from "@/shared/api";
import { env, settings, slash } from "@/shared/config";
import { t } from "@/shared/i18n";
import { SettingsDialog } from "@/widgets/settings";

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
 * waiting prompts, Board chips and bulk actions, the Graph, inspector operations with the drop confirmation, Ctrl+K,
 * the narrow sheet, Streams, the onboarding sheets with the claude-ledger import, and Settings › Ledger. Nothing leaves
 * the demo backend: the ledger core itself is blocked.
 */
export async function ledgerSelfTest(): Promise<[boolean, string]> {
  // loaded on demand, like the page itself, so the Ledger stays out of the start-up bundle
  const [{ DemoLedgerBackend, LedgerStore, ledgerStore, ledgerTracking, verdictCounts }, { LedgerWorkspace }] = await Promise.all([import("@/entities/ledger"), import("@/widgets/ledger-workspace")]);
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
    settings.set = (k, value) => { memory.set(k, value); version++; listeners.forEach((listener) => listener()); };
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
    root.render(<LedgerWorkspace repoPath="C:/fixture/atlas" ledger={store} />);
    ensure(await until(() => $(".ledger-page[data-layout='wide'] [data-view='inbox'] .ledger-prompts")), "The Inbox did not open with its waiting prompts");
    ensure(store.project === "atlas" && $$(".ledger-prompt").length === 3, `The Inbox must filter to this repository's project: ${store.project} prompts=${$$(".ledger-prompt").length}`);

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
    passed.push("waiting prompts");

    // Board: chips with counts, one verdict, bulk archive undone as one
    $<HTMLButtonElement>(".ledger-tabs [data-view='board']")!.click();
    ensure(await until(() => $(".ledger-board .ledger-table-row")), "The Board did not open");
    const counts = verdictCounts(store.state!.sessions, "atlas").filter((c) => c.count);
    const chips = $$(".ledger-chip .count").map((c) => Number(c.textContent));
    ensure(JSON.stringify(chips) === JSON.stringify(counts.map((c) => c.count)), `The chips must count verdicts: ${chips} vs ${counts.map((c) => c.count)}`);
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
    passed.push("board chips and bulk actions");

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

    // Narrow: the filters move above the view and the inspector becomes a sheet
    host.style.width = "620px";
    ensure(await until(() => $(".ledger-page[data-layout='narrow'] .ledger-topbar")), `A narrow page did not stack its filters: layout=${$(".ledger-page")?.dataset.layout} width=${$(".ledger-page")?.clientWidth} modal=${!!document.querySelector(".modal-backdrop")}`);
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
    stores.push(empty);
    root.render(<LedgerWorkspace repoPath={null} ledger={empty} />);
    ensure(await until(() => $(".ledger-onboarding .card")), "An empty ledger did not show the onboarding");
    ensure($$(".ledger-onboarding .card").some((card) => card.textContent?.includes(t("Import from claude-ledger")) && card.querySelector("button")), "The onboarding did not offer the claude-ledger import");
    button(".ledger-onboarding", "Paste reports")!.click();
    ensure(await until(() => $(".modal textarea")), "Paste reports did not open the import sheet");
    type($<HTMLTextAreaElement>(".modal textarea")!, '```ledger\n{"event":"start","session":"S1101-01","project":"atlas","title":"Imported in the self-test"}\n```\n```ledger\n{"event":"teleport"}\n```');
    $$<HTMLButtonElement>(".modal-footer button").at(-1)!.click();
    ensure(await until(() => $$(".ledger-result").length === 2 && empty.session("S1101-01")), "The import did not report each block and add the session");
    button(".modal-footer", "Close")!.click();
    await until(() => !$(".modal"));
    $<HTMLButtonElement>(`.ledger-toolbar button[aria-label="${t("Connect Claude Code")}"]`)!.click();
    ensure(await until(() => button(".modal", "Test connection")), "Connect Claude Code did not open");
    ensure($(".modal .ledger-code pre")?.textContent?.includes("claude mcp add --scope user gitrochi-ledger"), "The connect sheet did not show the command");
    button(".modal", "Test connection")!.click();
    ensure(await until(() => $(".modal .card[role='status']")), "Test connection did not answer");
    button(".modal", "Done")!.click();
    await until(() => !$(".modal"));
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
    button(".ledger-settings", "Connect Claude Code…")!.click();
    ensure(await until(() => button(".modal", "Test connection")), "Connect Claude Code… did not open from Settings");
    button(".modal", "Done")!.click();
    button(".ledger-settings", "Import from claude-ledger…")!.click();
    ensure(await until(() => button(".modal", "Choose a file")), "Import from claude-ledger… did not open from Settings");
    button(".modal-footer", "Close")!.click();
    passed.push("settings");

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
