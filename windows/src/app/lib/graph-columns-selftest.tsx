import { createRoot } from "react-dom/client";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { GraphView } from "@/widgets/commit-graph";
import { laneFixture } from "./graph-lanes-selftest";

const pause = (ms = 60) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** The optional author and time columns: off by default, turned on from the header's column menu, aligned with the row cells, dropped first on narrow widths. */
export async function graphColumnsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:1100px;height:520px;display:flex"; document.body.append(host);
  const root = createRoot(host);
  const saved = settings.get<unknown>("graphShownColumns", undefined);
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const q = (selector: string) => host.querySelector<HTMLElement>(selector);
  const menuItem = (label: string) => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.querySelector(".label")?.textContent === label);
  const checked = (label: string) => !!menuItem(label)?.querySelector(".check-mark svg");
  const openMenu = async () => { q(".graph-head-message .icon-btn")!.click(); await pause(); };
  const near = (a: number, b: number) => Math.abs(a - b) <= 1;
  try {
    settings.set("graphShownColumns", undefined);
    // thirty rows overflow the list, so its vertical scrollbar is in play for the alignment
    root.render(<GraphView store={laneFixture(30)} />); await pause(); await pause();
    ensure(!q(".head-author") && !q(".head-time") && !q(".commit-row .col-author") && !q(".commit-row .col-time"), "Author and time must be off by default");
    await openMenu();
    ensure(menuItem(t("Author")) && menuItem(t("Time")), "The column menu must offer Author and Time");
    ensure(checked(t("Branch / Tag")) && !checked(t("Author")) && !checked(t("Time")), "The column menu must show Author and Time unchecked by default");
    menuItem(t("Author"))!.click(); await pause();
    await openMenu();
    ensure(checked(t("Author")), "Author must be checked after turning it on");
    menuItem(t("Time"))!.click(); await pause();
    const shown = settings.get<string[]>("graphShownColumns", []);
    ensure(shown.includes("author") && shown.includes("time"), `The shown columns must be stored: ${JSON.stringify(shown)}`);
    const headAuthor = q(".graph-header .head-author"), headTime = q(".graph-header .head-time");
    const cellAuthor = q(".commit-row .col-author"), cellTime = q(".commit-row .col-time");
    ensure(headAuthor?.textContent === t("Author") && headTime?.textContent === t("Time"), "Turning them on must show the Author and Time header labels");
    ensure(cellAuthor?.textContent === "Author 0" && cellTime?.textContent, `Turning them on must show the row cells: ${cellAuthor?.textContent} · ${cellTime?.textContent}`);
    const [ha, hb, ca, cb] = [headAuthor!, headTime!, cellAuthor!, cellTime!].map((el) => el.getBoundingClientRect());
    ensure(near(ha.left, ca.left) && near(ha.right, ca.right) && near(hb.left, cb.left) && near(hb.right, cb.right), `The header labels must line up with the row cells: author ${ha.left}/${ca.left}, time ${hb.right}/${cb.right}`);
    // the graph column is 374 wide here: 1016 fits both, 924 only the author
    host.style.width = "960px"; await pause(); await pause();
    ensure(q(".head-author") && !q(".head-time") && q(".commit-row .col-author") && !q(".commit-row .col-time"), "A narrower window must drop the time first");
    host.style.width = "900px"; await pause(); await pause();
    ensure(!q(".head-author") && !q(".commit-row .col-author") && q(".commit-row .ref-col")?.offsetWidth === 190, "Then the author, before the branch column shrinks");
    return [true, "Off by default and unchecked in the menu, turned on from the menu and stored, header labels line up with the row cells, time and then author drop on narrow widths"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); settings.set("graphShownColumns", saved); window.dispatchEvent(new MouseEvent("mousedown")); }
}
