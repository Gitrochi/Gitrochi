import { createRoot } from "react-dom/client";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { GraphView } from "@/widgets/commit-graph";
import { laneFixture } from "./graph-lanes-selftest";

const pause = (ms = 60) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * The optional author, time and SHA columns: off by default, turned on from the header's column menu, aligned with the row cells,
 * dropped SHA-time-author on narrow widths, widened by dragging a label's left edge, the branch and graph columns resized by their right edge,
 * and put back by the menu's reset.
 */
export async function graphColumnsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:1100px;height:520px;display:flex"; document.body.append(host);
  const root = createRoot(host);
  const keys = ["graphShownColumns", "graphHiddenColumns", "graphColumnWidths"];
  const saved = keys.map((key) => settings.get<unknown>(key, undefined));
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const q = (selector: string) => host.querySelector<HTMLElement>(selector);
  const menuItem = (label: string) => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.querySelector(".label")?.textContent === label);
  const checked = (label: string) => !!menuItem(label)?.querySelector(".check-mark svg");
  const openMenu = async () => { q('.graph-head-tools [aria-label="' + t("Columns") + '"]')!.click(); await pause(); };
  const near = (a: number, b: number) => Math.abs(a - b) <= 1;
  try {
    keys.forEach((key) => settings.set(key, undefined));
    // thirty rows overflow the list, so its vertical scrollbar is in play for the alignment
    root.render(<GraphView store={laneFixture(30)} />); await pause(); await pause();
    ensure(!q(".head-opt") && !q(".commit-row .col-opt"), "Author, time and SHA must be off by default");
    await openMenu();
    ensure(menuItem(t("Author")) && menuItem(t("Date")) && menuItem(t("SHA")), "The column menu must offer Author, Date and SHA");
    ensure(checked(t("Branch / Tag")) && !checked(t("Author")) && !checked(t("Date")) && !checked(t("SHA")), "The column menu must show the optional columns unchecked by default");
    menuItem(t("Author"))!.click(); await pause();
    await openMenu();
    ensure(checked(t("Author")), "Author must be checked after turning it on");
    menuItem(t("Date"))!.click(); await pause();
    const shown = settings.get<string[]>("graphShownColumns", []);
    ensure(shown.includes("author") && shown.includes("time"), `The shown columns must be stored: ${JSON.stringify(shown)}`);
    const headAuthor = q(".graph-header .head-author"), headTime = q(".graph-header .head-time");
    const cellAuthor = q(".commit-row .col-author"), cellTime = q(".commit-row .col-time");
    ensure(headAuthor?.textContent === t("Author") && headTime?.textContent === t("Date"), "Turning them on must show the Author and Date header labels");
    ensure(cellAuthor?.textContent === "Author 0" && cellTime?.textContent, `Turning them on must show the row cells: ${cellAuthor?.textContent} · ${cellTime?.textContent}`);
    const [ha, hb, ca, cb] = [headAuthor!, headTime!, cellAuthor!, cellTime!].map((el) => el.getBoundingClientRect());
    ensure(near(ha.left, ca.left) && near(ha.right, ca.right) && near(hb.left, cb.left) && near(hb.right, cb.right), `The header labels must line up with the row cells: author ${ha.left}/${ca.left}, time ${hb.right}/${cb.right}`);
    // the graph column is 198 wide here (eight lanes): 884 fits both, 800 only the author
    host.style.width = "860px"; await pause(); await pause();
    ensure(q(".head-author") && !q(".head-time") && q(".commit-row .col-author") && !q(".commit-row .col-time"), "A narrower window must drop the time first");
    host.style.width = "780px"; await pause(); await pause();
    ensure(!q(".head-author") && !q(".commit-row .col-author") && q(".commit-row .ref-col")?.offsetWidth === 190, "Then the author, before the branch column shrinks");
    host.style.width = "1100px"; await pause(); await pause();
    await openMenu();
    menuItem(t("SHA"))!.click(); await pause();
    ensure(q(".head-sha")?.textContent === t("SHA") && q(".commit-row .col-sha")?.textContent?.length === 7, `Turning SHA on must show the short SHA: ${q(".commit-row .col-sha")?.textContent}`);
    // dragging the author label's left edge 40px to the left widens it by 40, in the header and in the rows
    const handle = q(".head-author .col-resizer")!, x = handle.getBoundingClientRect().left + 4;
    handle.dispatchEvent(new PointerEvent("pointerdown", { clientX: x, button: 0, bubbles: true }));
    window.dispatchEvent(new PointerEvent("pointermove", { clientX: x - 40 })); await pause();
    window.dispatchEvent(new PointerEvent("pointerup", { clientX: x - 40 })); await pause();
    const widths = settings.get<Record<string, number>>("graphColumnWidths", {});
    ensure(widths.author === 160 && q(".head-author")?.offsetWidth === 160 && q(".commit-row .col-author")?.offsetWidth === 160, `Dragging must widen the author column and store it: ${JSON.stringify(widths)} ${q(".head-author")?.offsetWidth}`);
    // the branch and graph columns' right edges: dragging right widens, left narrows, and the message takes up the difference
    const dragRight = async (selector: string, dx: number) => {
      const edge = q(selector)!, x0 = edge.getBoundingClientRect().left + 4;
      edge.dispatchEvent(new PointerEvent("pointerdown", { clientX: x0, button: 0, bubbles: true }));
      window.dispatchEvent(new PointerEvent("pointermove", { clientX: x0 + dx })); await pause();
      window.dispatchEvent(new PointerEvent("pointerup", { clientX: x0 + dx })); await pause();
    };
    const message = () => q(".graph-head-message")!.offsetWidth;
    const before = message();
    await dragRight(".head-ref .col-resizer", 30);
    ensure(q(".head-ref")?.offsetWidth === 220 && q(".commit-row .ref-col")?.offsetWidth === 220 && settings.get<Record<string, number>>("graphColumnWidths", {}).ref === 220,
      `Dragging the branch column's right edge must widen it in the header and rows and store it: ${q(".head-ref")?.offsetWidth} ${q(".commit-row .ref-col")?.offsetWidth}`);
    const graph = q(".graph-head-cell")!.offsetWidth;
    await dragRight(".graph-head-cell .col-resizer", -60);
    ensure(q(".graph-head-cell")?.offsetWidth === graph - 60 && q(".commit-row .graph-cell")?.offsetWidth === graph - 60 && q(".lane-scrollbar"),
      `Dragging the graph column's right edge left must narrow it, with the lanes scrolling: ${graph} → ${q(".graph-head-cell")?.offsetWidth}`);
    ensure(near(message(), before - 30 + 60), `The message column must take up the difference: ${before} → ${message()}`);
    await openMenu();
    menuItem(t("Reset to default layout"))!.click(); await pause();
    ensure(!q(".head-opt") && settings.get<string[]>("graphShownColumns", []).length === 0 && Object.keys(settings.get<object>("graphColumnWidths", {})).length === 0, "Reset must put back the default columns and widths");
    return [true, "Off by default and unchecked in the menu, turned on from the menu and stored, header labels line up with the row cells, time and then author drop on narrow widths, SHA shows the short id, a drag widens a column, the branch and graph columns resize by their right edge, and the reset puts the default layout back"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); keys.forEach((key, i) => settings.set(key, saved[i])); window.dispatchEvent(new MouseEvent("mousedown")); }
}
