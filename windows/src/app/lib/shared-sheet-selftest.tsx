import { useState } from "react";
import { createRoot } from "react-dom/client";
import { t } from "@/shared/i18n";
import { Button, SharedSheet } from "@/shared/ui";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 30));
async function until(test: () => boolean) {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(); }
  return false;
}

/** The shared sheet keeps its one layout: it hangs from the toolbar without dimming the window (docs/design.md, App shell). */
export async function sharedSheetSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  document.body.append(host);
  // the app's toolbar is the anchor; a page without one gets a stand-in so the step measures the same thing
  const ownAnchor = document.querySelector("[data-sheet-anchor]") ? null : Object.assign(document.createElement("div"), { style: "position:fixed;left:0;top:0;right:0;height:52px" });
  if (ownAnchor) { ownAnchor.dataset.sheetAnchor = ""; document.body.append(ownAnchor); }
  const root = createRoot(host);
  let closed = 0, confirmed = 0, tested = 0;
  let block = (_reason: string | null) => {};
  let hold = (_working: boolean) => {};
  let reopen = () => {};
  function Fixture() {
    const [reason, setReason] = useState<string | null>("Enter a name first");
    const [open, setOpen] = useState(true);
    const [working, setWorking] = useState(false);
    block = setReason;
    hold = setWorking;
    reopen = () => setOpen(true);
    if (!open) return null;
    return (
      <SharedSheet className="fixture-sheet" title="Fixture sheet" context="desktop · feature/shared-sheet" width={480} cancelDisabled={working} onClose={() => { closed++; setOpen(false); }}
        secondary={<Button className="fixture-secondary" onClick={() => tested++}>Test</Button>}
        primary={{ label: "Confirm", onClick: () => confirmed++, disabledReason: reason }}>
        <span className="fixture-content">Content</span>
      </SharedSheet>
    );
  }
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const box = (selector: string) => $(selector)!.getBoundingClientRect();
  const style = (selector: string) => getComputedStyle($(selector)!);
  const details: string[] = [];
  try {
    root.render(<Fixture />);
    const anchor = Math.round(document.querySelector("[data-sheet-anchor]")!.getBoundingClientRect().bottom);
    // the sheet drops in; measure once it rests under the toolbar
    if (!await until(() => !!$(".fixture-sheet") && Math.abs(box(".fixture-sheet").top - anchor) < 0.5)) return [false, `The sheet did not attach under the toolbar: top=${$(".fixture-sheet")?.getBoundingClientRect().top} toolbar=${anchor}`];

    // attached, centred, square on top, and the window is not dimmed
    const sheet = $(".fixture-sheet")!, backdrop = sheet.parentElement!;
    if (Math.abs((box(".fixture-sheet").left + box(".fixture-sheet").right) / 2 - window.innerWidth / 2) > 1) return [false, "The sheet is not horizontally centred"];
    if (style(".fixture-sheet").borderTopLeftRadius !== "0px" || style(".fixture-sheet").borderBottomLeftRadius !== "12px") return [false, "The sheet must be square on top with 12px corners below"];
    if (!backdrop.classList.contains("modal-backdrop")) return [false, "Keyboard handlers find an open dialog by .modal-backdrop"];
    if (!/rgba\(0, 0, 0, 0\)|transparent/.test(getComputedStyle(backdrop).backgroundColor)) return [false, `The window behind a sheet must not be dimmed: ${getComputedStyle(backdrop).backgroundColor}`];
    details.push("attached, not dimmed");

    // header: 15px semibold title, one 12px context line, 20px padding, a 1px line
    const title = $(".fixture-sheet .shared-sheet-title")!, context = $(".fixture-sheet .shared-sheet-context")!;
    if (sheet.getAttribute("role") !== "dialog" || sheet.getAttribute("aria-labelledby") !== title.id || sheet.getAttribute("aria-describedby") !== context.id) return [false, "The sheet must be a dialog named by its title and described by its context"];
    if (style(".fixture-sheet .shared-sheet-title").fontSize !== "15px" || style(".fixture-sheet .shared-sheet-title").fontWeight !== "600") return [false, "The title must be 15px semibold"];
    if (style(".fixture-sheet .shared-sheet-context").fontSize !== "12px" || style(".fixture-sheet .shared-sheet-context").whiteSpace !== "nowrap") return [false, "The context must be one 12px line"];
    const header = style(".fixture-sheet .shared-sheet-header");
    if (header.paddingTop !== "20px" || header.paddingLeft !== "20px" || header.borderBottomWidth !== "1px") return [false, "The header needs 20px padding over a 1px line"];
    details.push("header");

    // footer: secondary on the left; on the right Cancel, the reason, then the one filled primary
    const secondary = box(".fixture-secondary"), cancel = box(".shared-sheet-cancel"), reason = box(".shared-sheet-footer .disabled-reason-text"), primary = box(".shared-sheet-primary");
    if (!(secondary.right <= cancel.left && cancel.right <= reason.left && reason.right <= primary.left)) return [false, "Footer order must be secondary · Cancel · reason · primary"];
    if (Math.abs(secondary.left - box(".fixture-sheet").left - 20) > 1 || Math.abs(box(".fixture-sheet").right - primary.right - 20) > 1) return [false, "The footer keeps 20px at both sides"];
    if (cancel.left - secondary.right < 40) return [false, "Secondary actions stay on the left, away from Cancel"];
    const confirm = $<HTMLButtonElement>(".shared-sheet-primary")!, why = $(".shared-sheet-footer .disabled-reason-text")!;
    if (!confirm.disabled || why.textContent !== "Enter a name first" || confirm.getAttribute("aria-describedby") !== why.id) return [false, "A disabled primary must say why beside it"];
    if ($(".shared-sheet-cancel")!.textContent !== t("Cancel") || host.querySelectorAll(".shared-sheet-footer .btn.primary").length !== 1) return [false, "The footer has Cancel and one filled primary"];
    $<HTMLButtonElement>(".fixture-secondary")!.click();
    block(null);
    // without a reason the button stands alone, so look it up again
    if (!await until(() => $<HTMLButtonElement>(".shared-sheet-primary")?.disabled === false && !$(".shared-sheet-footer .disabled-reason-text"))) return [false, "The reason must go once the primary can be used"];
    $<HTMLButtonElement>(".shared-sheet-primary")!.click();
    if (!await until(() => confirmed === 1 && tested === 1)) return [false, "The footer's actions did not run"];
    details.push("footer");

    // while its work is under way the sheet can't be left: not by Cancel, Escape or a click outside
    hold(true);
    if (!await until(() => $<HTMLButtonElement>(".shared-sheet-cancel")?.disabled === true)) return [false, "Cancel must be disabled while the sheet works"];
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    $(".fixture-sheet")!.parentElement!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    for (let turn = 0; turn < 5; turn++) await pause();
    if (closed !== 0 || !$(".fixture-sheet")) return [false, "Escape or a click outside closed a sheet whose work was under way"];
    hold(false);
    if (!await until(() => $<HTMLButtonElement>(".shared-sheet-cancel")?.disabled === false)) return [false, "Cancel must come back once the work is done"];
    details.push("held while working");

    // Cancel, Escape and a click outside close it
    $<HTMLButtonElement>(".shared-sheet-cancel")!.click();
    if (!await until(() => closed === 1 && !$(".fixture-sheet"))) return [false, "Cancel did not close the sheet"];
    reopen();
    if (!await until(() => !!$(".fixture-sheet"))) return [false, "The sheet did not open again"];
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    if (!await until(() => closed === 2 && !$(".fixture-sheet"))) return [false, "Escape did not close the sheet"];
    reopen();
    if (!await until(() => !!$(".fixture-sheet"))) return [false, "The sheet did not open a third time"];
    $(".fixture-sheet")!.parentElement!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    if (!await until(() => closed === 3 && !$(".fixture-sheet"))) return [false, "A click outside did not close the sheet"];
    details.push("closing");
    return [true, details.join(", ")];
  } finally { root.unmount(); host.remove(); ownAnchor?.remove(); }
}
