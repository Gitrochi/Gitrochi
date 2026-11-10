import { useState } from "react";
import { createRoot } from "react-dom/client";
import { KeyRound } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { Button, DisabledReason, FailureBlock, FailureRow, NoticeBlock, retryAbove } from "@/shared/ui";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 30));
async function until(test: () => boolean) {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(); }
  return false;
}

/** The failure block, the notice block and the disabled-reason pattern keep their one form (docs/design.md, Controls). */
export async function noticeBlockSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: "520px", visibility: "hidden" });
  document.body.append(host);
  const root = createRoot(host);
  let retried = 0, approved = 0, rowRetried = 0;
  let fail = (_retrying: boolean) => {};
  function Fixture() {
    const [retrying, setRetrying] = useState(false);
    fail = setRetrying;
    return <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <FailureBlock className="fixture-failure" title={t("Couldn't reach {0}", "github.com")} caption={t("Showing data from {0}", "12m")} retrying={retrying} retry={() => retried++} />
      <NoticeBlock className="fixture-one" icon={<KeyRound size={14} />} title="One action" caption="Caption" actions={[{ label: "Approve…", filled: true, onClick: () => approved++ }]} />
      <NoticeBlock className="fixture-two" icon={<KeyRound size={14} />} title="Two actions" caption="Caption" actions={[{ label: "First", onClick: () => {} }, { label: "Second", onClick: () => {} }]} />
      <div style={{ width: 240 }}><NoticeBlock className="fixture-narrow" icon={<KeyRound size={14} />} title="Saved sign-in needs your approval" actions={[{ label: "Restore saved account access", onClick: () => {} }]} /></div>
      <div style={{ width: 240 }}><FailureRow className="fixture-row" title={t("Couldn't read the saved account credentials")} caption="Caption" retry={() => rowRetried++} /></div>
      <div className="fixture-footer" style={{ display: "flex" }}>
        <DisabledReason reason={retryAbove()}><Button kind="primary" className="fixture-blocked">Confirm</Button></DisabledReason>
        <DisabledReason reason={null}><Button className="fixture-open">Open</Button></DisabledReason>
      </div>
    </div>;
  }
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const box = (selector: string) => $(selector)!.getBoundingClientRect();
  const details: string[] = [];
  try {
    root.render(<Fixture />);
    if (!await until(() => !!$(".fixture-failure .btn"))) return [false, "Failure block did not mount"];

    // failure: the failed tone, an alert, the 13px semibold title, the 12px caption and a plain Retry on the right
    const failure = $(".fixture-failure")!;
    const title = $(".fixture-failure .notice-block-title")!, caption = $(".fixture-failure .notice-block-caption")!;
    const retry = $<HTMLButtonElement>(".fixture-failure .notice-block-body > .notice-block-actions .btn")!;
    if (failure.dataset.tone !== "failed" || failure.getAttribute("role") !== "alert") return [false, "Failure block lost its tone or alert role"];
    if (getComputedStyle(title).fontSize !== "13px" || getComputedStyle(title).fontWeight !== "600" || getComputedStyle(caption).fontSize !== "12px") return [false, "Failure block type sizes changed"];
    if (!retry || retry.textContent !== t("Retry") || retry.classList.contains("primary")) return [false, "Failure block needs a plain Retry"];
    if (box(".fixture-failure .notice-block-actions").left < box(".fixture-failure .notice-block-text").right) return [false, "Retry must sit on the right of the words"];
    retry.click();
    if (!await until(() => retried === 1)) return [false, "Retry did not run"];
    fail(true);
    if (!await until(() => !!$(".fixture-failure .spinner") && retry.disabled)) return [false, "A retry under way must show its spinner and wait"];
    fail(false);
    if (!await until(() => !$(".fixture-failure .spinner") && !retry.disabled)) return [false, "Retry did not come back after the retry finished"];
    details.push("failure");

    // one action on the right, two on a row below the words
    if (!$(".fixture-one .notice-block-body > .notice-block-actions") || $(".fixture-one .notice-block-text > .notice-block-actions")) return [false, "One action must sit on the right"];
    if (box(".fixture-one .notice-block-body > .notice-block-actions").left < box(".fixture-one .notice-block-text").right) return [false, "One action overlaps the words"];
    $<HTMLButtonElement>(".fixture-one .btn.primary")!.click();
    if (!await until(() => approved === 1)) return [false, "Notice action did not run"];
    const row = $(".fixture-two .notice-block-text > .notice-block-actions");
    if (!row || row.querySelectorAll(".btn").length !== 2 || $(".fixture-two .notice-block-body > .notice-block-actions")) return [false, "Two actions must go on a row below"];
    if (box(".fixture-two .notice-block-text > .notice-block-actions").top < box(".fixture-two .notice-block-caption").bottom) return [false, "The action row must sit below the caption"];
    // in a narrow column (a sidebar section) the one action drops below the words instead of squeezing them
    if (box(".fixture-narrow .notice-block-title").width < 150) return [false, "A narrow notice squeezed its words"];
    if (box(".fixture-narrow .notice-block-actions").top < box(".fixture-narrow .notice-block-title").bottom) return [false, "A narrow notice must put its action below the words"];
    // the sidebar's row: one line as tall as its neighbours, the title cut short rather than wrapped, Retry on the right
    const sidebarRow = $(".fixture-row")!;
    if (sidebarRow.getBoundingClientRect().height > 26) return [false, `A sidebar notice row is ${sidebarRow.getBoundingClientRect().height}px tall`];
    if (getComputedStyle($(".fixture-row .notice-row-title")!).textOverflow !== "ellipsis" || !sidebarRow.title.includes("Caption")) return [false, "A sidebar notice row must cut its title and keep the caption on hover"];
    $<HTMLButtonElement>(".fixture-row .notice-row-action")!.click();
    if (!await until(() => rowRetried === 1)) return [false, "A sidebar notice row's Retry did not run"];
    details.push("notice");

    // a disabled button says why, 8px beside it, and is neutral rather than faded
    const blocked = $<HTMLButtonElement>(".fixture-blocked")!, reason = $(".fixture-footer .disabled-reason-text")!;
    if (!blocked.disabled || reason.textContent !== t("Retry above") || blocked.getAttribute("aria-describedby") !== reason.id) return [false, "Blocked primary lost its reason"];
    const gap = blocked.getBoundingClientRect().left - reason.getBoundingClientRect().right;
    if (Math.abs(gap - 8) > 1) return [false, `Reason sits ${gap}px from its button`];
    if (getComputedStyle(blocked).opacity !== "1") return [false, "A disabled button must not be faded"];
    const open = $<HTMLButtonElement>(".fixture-open")!;
    if (open.disabled || open.parentElement?.classList.contains("disabled-reason")) return [false, "A button without a reason must stay as it is"];
    details.push("disabled reason");
    return [true, details.join(", ")];
  } finally { root.unmount(); host.remove(); }
}
