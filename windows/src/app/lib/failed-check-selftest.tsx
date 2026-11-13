import { useState } from "react";
import { createRoot } from "react-dom/client";
import { CircleX } from "@/shared/icons";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { failedTests, numberedLog } from "@/shared/lib";
import { CheckGroupHead, CheckLog, checkLogMenu, FailedCheckBlock } from "@/shared/ui";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 30));
async function until(test: () => boolean) {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(); }
  return false;
}

// 46 lines whose first error is line 41, so the log opens on line 38; line 45 is far longer than the box is wide
const output = Array.from({ length: 46 }, (_, index) => {
  const n = index + 1;
  if (n === 41) return `TerminalFocusTests.swift:58: error: XCTAssertTrue failed - terminal lost focus after paste ${"and the reason goes on ".repeat(8)}`;
  if (n === 42) return "Test Case 'TerminalFocusTests.testFocusAfterPaste' failed (0.031 seconds).";
  if (n === 45) return `Executed 231 tests, with 1 failure (0 unexpected) in 19.204 seconds ${"x".repeat(400)}`;
  return `line ${n}`;
});

/** The failed-check block, its log and the group heads keep their one form (docs/design.md, Shared components). */
export async function failedCheckSelfTest(): Promise<[boolean, string]> {
  // the log's wrapping is a saved setting another step may have turned on
  const wrapBefore = settings.get<boolean>("ciLogWrap", false);
  settings.set("ciLogWrap", false);
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: "720px", visibility: "hidden" });
  document.body.append(host);
  const root = createRoot(host);
  let reran = 0, opened = 0, copied = 0;
  const lines = numberedLog(output), tests = failedTests(output);
  function Fixture() {
    const [jump, setJump] = useState(0), [open, setOpen] = useState(false);
    const block = (className: string, withLog: boolean) => (
      <FailedCheckBlock className={className} form="card" icon={<CircleX size={14} />} name="test-macos" outcome={t("Failed after {0}", "3m 12s")} tests={tests}
        onJump={() => setJump((value) => value + 1)} rerun={{ label: t("Re-run job"), onClick: () => reran++ }} onOpen={() => opened++}
        menu={() => checkLogMenu(() => copied++)}>
        {withLog && <CheckLog label="test-macos" lines={lines} jump={jump} />}
      </FailedCheckBlock>
    );
    return <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <CheckGroupHead className="fixture-failed-head" title={t("Failed")} />
      {block("fixture-wide", true)}
      <CheckGroupHead className="fixture-passed-head" title={t("Passed")} count={5} open={open} onToggle={() => setOpen(!open)} />
      <div style={{ width: 260 }}>{block("fixture-narrow", false)}</div>
    </div>;
  }
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const box = (selector: string) => $(selector)!.getBoundingClientRect();
  const style = (selector: string) => getComputedStyle($(selector)!);
  const details: string[] = [];
  try {
    root.render(<Fixture />);
    if (!await until(() => !!$(".fixture-wide .check-log-line"))) return [false, "Failed-check block did not mount"];

    // header: name in monospaced 13 semibold, "Failed after …" in the failed tone, a 12px caption naming the test, then the actions in order
    if (style(".fixture-wide .failed-check-name").fontSize !== "13px" || style(".fixture-wide .failed-check-name").fontWeight !== "600") return [false, "The job name must be 13px semibold"];
    const outcome = $(".fixture-wide .failed-check-outcome")!;
    if (outcome.textContent !== t("Failed after {0}", "3m 12s") || outcome.dataset.tone !== "failed" || style(".fixture-wide .failed-check-outcome").fontSize !== "12px") return [false, "The outcome must say Failed after … in the failed tone"];
    const caption = $(".fixture-wide .failed-check-caption")!;
    if (style(".fixture-wide .failed-check-caption").fontSize !== "12px" || caption.textContent !== `${t("1 test failed:")} TerminalFocusTests.testFocusAfterPaste`) return [false, `The caption must name the failed test: ${caption.textContent}`];
    const buttons = [...host.querySelectorAll<HTMLButtonElement>(".fixture-wide .failed-check-actions .btn")];
    const labels = buttons.map((button) => button.textContent?.trim() || button.getAttribute("aria-label"));
    if (labels.join("|") !== [t("Jump to first error"), t("Re-run job"), t("Open in browser"), t("More job actions")].join("|")) return [false, `Actions are out of order: ${labels.join("|")}`];
    if (box(".fixture-wide .failed-check-actions").left < box(".fixture-wide .failed-check-title").right - 1) return [false, "The actions must sit on the right of the words"];
    buttons[1].click(); buttons[2].click();
    if (!await until(() => reran === 1 && opened === 1)) return [false, "Re-run job or open in browser did not run"];
    details.push("header");

    // log: opens three lines before its first error; an error line wraps inside the box, the others scroll under a right-edge fade
    const scroll = $(".fixture-wide .check-log-scroll")!;
    if ($(".fixture-wide .check-log-earlier button")?.textContent !== t("Show {0} earlier lines", 37) || $(".fixture-wide .check-log-n")?.textContent !== "38") return [false, "The log must open three lines before its first error"];
    const error = $('.fixture-wide [data-line="41"]')!, long = $('.fixture-wide [data-line="45"]')!;
    if (!error.classList.contains("error") || error.dataset.tone !== "failed" || getComputedStyle(error).whiteSpace !== "pre-wrap") return [false, "An error line must wrap in the failed tone"];
    if (error.getBoundingClientRect().width > scroll.clientWidth + 1 || error.getBoundingClientRect().height < 40) return [false, "An error line must wrap inside the visible box"];
    if (getComputedStyle(long).whiteSpace !== "pre" || scroll.scrollWidth <= scroll.clientWidth) return [false, "Other lines must keep their length and scroll sideways"];
    if (!await until(() => !!$(".fixture-wide .check-log-fade"))) return [false, "A log with more to the right must fade its right edge"];
    scroll.scrollLeft = scroll.scrollWidth;
    scroll.dispatchEvent(new Event("scroll"));
    if (!await until(() => !$(".fixture-wide .check-log-fade"))) return [false, "The fade must go once the log is scrolled to its end"];
    scroll.scrollLeft = 0;
    scroll.dispatchEvent(new Event("scroll"));
    $<HTMLButtonElement>(".fixture-wide .check-log-earlier button")!.click();
    if (!await until(() => $(".fixture-wide .check-log-n")?.textContent === "1" && !$(".fixture-wide .check-log-earlier"))) return [false, "Show earlier lines did not show them"];
    // Jump to first error brings the first error line back into the box
    scroll.scrollTop = 0;
    buttons[0].click();
    const inBox = () => { const line = error.getBoundingClientRect(), view = scroll.getBoundingClientRect(); return line.top >= view.top - 1 && line.bottom <= view.bottom + 1; };
    if (!await until(inBox)) return [false, "Jump to first error did not show the first error"];
    details.push("log");

    // ⋯ holds Wrap long lines and Copy log; wrapping every line leaves nothing to scroll or fade
    buttons[3].click();
    const item = (label: string) => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((entry) => entry.textContent?.trim() === label);
    if (!await until(() => !!item(t("Wrap long lines")) && !!item(t("Copy log")))) return [false, "⋯ must hold Wrap long lines and Copy log"];
    item(t("Copy log"))!.click();
    if (!await until(() => copied === 1)) return [false, "Copy log did not run"];
    buttons[3].click();
    if (!await until(() => !!item(t("Wrap long lines")))) return [false, "⋯ did not open again"];
    item(t("Wrap long lines"))!.click();
    if (!await until(() => !!$(".fixture-wide .check-log.wrap") && getComputedStyle(long).whiteSpace === "pre-wrap" && scroll.scrollWidth <= scroll.clientWidth + 1 && !$(".fixture-wide .check-log-fade"))) return [false, "Wrap long lines must wrap every line"];
    details.push("menu");

    // a narrow column (an inspector) keeps the words whole: the actions drop below them and stay inside the block
    const narrow = box(".fixture-narrow");
    if (box(".fixture-narrow .failed-check-name").width < $(".fixture-narrow .failed-check-name")!.scrollWidth - 1) return [false, "A narrow block cut the job name"];
    if (box(".fixture-narrow .failed-check-actions").top < box(".fixture-narrow .failed-check-title").bottom) return [false, "A narrow block must put its actions below the words"];
    for (const button of host.querySelectorAll(".fixture-narrow .failed-check-actions .btn")) {
      const rect = button.getBoundingClientRect();
      if (rect.right > narrow.right + 1 || rect.left < narrow.left - 1) return [false, "A narrow block's action leaves the block"];
    }
    if (box(".fixture-narrow .failed-check-caption").right > narrow.right + 1) return [false, "A narrow block's caption leaves the block"];
    details.push("narrow");

    // group heads: "Failed" alone where a tab counts it, "Passed 5"; a head with a group to fold is a button
    if ($(".fixture-failed-head")!.textContent !== t("Failed") || $(".fixture-failed-head")!.tagName !== "SPAN") return [false, "A group head without a count must be its title alone"];
    const passed = $<HTMLButtonElement>(".fixture-passed-head")!;
    if (passed.textContent !== `${t("Passed")} 5` || passed.getAttribute("aria-expanded") !== "false") return [false, "A folded group head must say Passed 5"];
    passed.click();
    if (!await until(() => passed.getAttribute("aria-expanded") === "true")) return [false, "A group head did not unfold"];
    details.push("group heads");
    return [true, details.join(", ")];
  } finally {
    window.dispatchEvent(new MouseEvent("mousedown"));
    root.unmount();
    host.remove();
    settings.set("ciLogWrap", wrapBefore);
  }
}
