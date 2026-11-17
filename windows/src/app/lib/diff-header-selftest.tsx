import { createRoot } from "react-dom/client";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { DiffHeader, FileViewToggle, type MenuItem } from "@/shared/ui";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const frames = () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
const until = async (done: () => boolean, ms = 2500) => {
  const end = Date.now() + ms;
  while (!done() && Date.now() < end) await pause(20);
  return done();
};

/**
 * The shared diff header and the list/tree toggle as the boards draw them: one 44px row with the 28px segmented
 * control, nothing clipped or squeezed down to 420px (the folder goes first, then the position, then Ask AI… and Hide
 * whitespace move into More, the name is cut last), and the toggle's icon form with its pressed state.
 */
export async function diffHeaderSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set };
  const memory = new Map<string, unknown>([["fileViewMode", "list"]]);
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: "900px", display: "flex", flexDirection: "column", visibility: "hidden" });
  document.body.append(host);
  const root = createRoot(host);
  const calls: string[] = [];
  const one = <T extends HTMLElement = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const menuLabels = () => [...document.querySelectorAll(".menu .menu-item .label")].map((item) => item.textContent);
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    const more = (): MenuItem[] => [{ label: t("Copy path"), onClick: () => calls.push("copy") }];
    const render = () => root.render(<>
      <DiffHeader
        back={{ label: t("Back to conversation"), tip: t("Back to conversation"), onClick: () => calls.push("back") }}
        badge={<span className="status-badge" style={{ width: 18, height: 18 }}/>}
        path="macos/Sources/Views/Search/SearchPanel.swift"
        position={{ index: 1, count: 6, step: (by) => calls.push(`step${by}`) }}
        layout={{ split: false, set: (value) => calls.push(`split:${value}`), disabledReason: t("Split needs a diff at least 1000 px wide") }}
        whitespace={{ hidden: false, set: (value) => calls.push(`whitespace:${value}`) }}
        ask={{ run: () => calls.push("ask") }}
        more={more}
      />
      <div className="row" style={{ padding: 8 }}><FileViewToggle/></div>
    </>);
    // the fixture's settings tell nobody that they changed, so the toggle is drawn again by hand
    settings.set = (key, value) => { memory.set(key, value); render(); };
    render();
    if (!await until(() => !!one(".diff-header"))) return [false, "The diff header did not mount"];
    const header = one(".diff-header")!, row = one(".diff-header-row")!;
    const has = (selector: string) => !!header.querySelector(selector);
    const state = () => ({
      fold: Number(header.dataset.fold), fits: row.scrollWidth <= row.clientWidth, height: Math.round(header.getBoundingClientRect().height),
      folder: has(".diff-header-folder"), position: has(".diff-header-count"), ask: has(".diff-header-text"),
      whitespace: has(`[aria-label="${t("Hide whitespace")}"]`), cut: has(".diff-header-name.cut"),
    });
    const widths = [900, 700, 560, 480, 420];
    const seen: ReturnType<typeof state>[] = [];
    for (const width of widths) {
      host.style.width = `${width}px`;
      await frames(); await frames();
      // the fold settles within the frame it is measured in; wait for it to stop moving
      let last = -1;
      await until(() => { const now = Number(header.dataset.fold); const settled = now === last; last = now; return settled; });
      seen.push(state());
    }
    const wide = seen[0];
    const full = wide.fold === 0 && wide.folder && wide.position && wide.ask && wide.whitespace && !wide.cut;
    const oneRow = seen.every((item) => item.height === 44 && item.fits);
    // what gives way keeps its order: no position without room for it before Ask AI… goes, and the name is cut last
    const ordered = seen.every((item, index) => (index === 0 || item.fold >= seen[index - 1].fold)
      && (item.position ? true : !item.folder) && (item.ask ? true : !item.position) && (item.whitespace ? true : !item.ask) && (item.cut ? !item.whitespace : true));
    const narrow = seen[widths.indexOf(420)];
    const folded = !narrow.folder && !narrow.position;
    // More lists what the row had no room for first, then the screen's own items
    host.style.width = "420px";
    await frames(); await frames();
    one<HTMLButtonElement>(`[aria-label="${t("More file actions")}"]`)?.click();
    const menuShown = await until(() => menuLabels().includes(t("Copy path")));
    const labels = menuLabels();
    window.dispatchEvent(new MouseEvent("mousedown"));
    const menuGone = await until(() => !document.querySelector(".menu"));
    const menu = menuShown && menuGone && labels[0] === t("Previous file (K)") && labels[1] === t("Next file (J)") && labels.at(-1) === t("Copy path")
      && (narrow.ask || labels.includes(t("Ask AI…"))) && (narrow.whitespace || labels.includes(t("Hide whitespace")));

    host.style.width = "900px";
    await frames(); await frames();
    await until(() => Number(header.dataset.fold) === 0);
    const layout = one(`.diff-header .segmented[aria-label="${t("Diff layout")}"]`);
    const split = layout?.querySelector<HTMLButtonElement>(".segmented-off button");
    const segmented = !!layout && Math.round(layout.getBoundingClientRect().height) === 28 && getComputedStyle(layout).borderRadius === "6px"
      && layout.querySelector("button.on")?.textContent === t("Unified") && layout.querySelector("button.on")?.getAttribute("aria-pressed") === "true"
      && !!split?.disabled && layout.querySelector(".segmented-off")?.getAttribute("data-tip") === t("Split needs a diff at least 1000 px wide");
    one<HTMLButtonElement>(`[aria-label="${t("Next file (J)")}"]`)?.click();
    one<HTMLButtonElement>(`[aria-label="${t("Hide whitespace")}"]`)?.click();
    one<HTMLButtonElement>(".diff-header-text")?.click();
    one<HTMLButtonElement>(".diff-back")?.click();
    const controls = calls.join() === "step1,whitespace:true,ask,back" && one(".diff-back")?.nextElementSibling?.className === "diff-back-sep";

    // the list/tree toggle: two 28 × 24 icon segments in the 28px control, named by their tooltips
    const toggle = one(`.segmented[aria-label="${t("File list layout")}"]`);
    const buttons = [...(toggle?.querySelectorAll<HTMLButtonElement>("button") ?? [])];
    const size = (element: Element) => { const box = element.getBoundingClientRect(); return `${Math.round(box.width)}x${Math.round(box.height)}`; };
    const pressed = () => buttons.map((button) => button.getAttribute("aria-pressed")).join();
    const before = pressed();
    buttons[1]?.click();
    const switched = await until(() => pressed() === "false,true") && memory.get("fileViewMode") === "tree";
    buttons[0]?.click();
    const restored = await until(() => pressed() === "true,false") && memory.get("fileViewMode") === "list";
    const icons = !!toggle && size(toggle) === "62x28" && buttons.length === 2 && buttons.every((button) => size(button) === "28x24" && !!button.querySelector("svg") && !button.textContent)
      && buttons[0].getAttribute("aria-label") === t("Show as list") && buttons[1].getAttribute("aria-label") === t("Show as folder tree")
      && buttons[1].dataset.tip === t("Show as folder tree") && before === "true,false" && switched && restored;

    const ok = full && oneRow && ordered && folded && menu && segmented && controls && icons;
    return [ok, JSON.stringify({ full, oneRow, ordered, folded, menu, segmented, controls, icons, folds: seen.map((item) => item.fold).join(), rows: seen.map((item) => `${item.height}/${item.fits}`).join(), labels })];
  } finally {
    if (document.querySelector(".menu")) { window.dispatchEvent(new MouseEvent("mousedown")); await until(() => !document.querySelector(".menu"), 500); }
    root.unmount(); await pause(25); host.remove();
    settings.get = original.get; settings.set = original.set;
  }
}
