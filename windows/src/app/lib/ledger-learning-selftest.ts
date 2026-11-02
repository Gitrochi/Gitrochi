import { LEDGER_LEARNING_SETTING, type DemoLedgerBackend } from "@/entities/ledger";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
async function until(test: () => unknown) {
  const end = Date.now() + 4000;
  while (Date.now() < end) { if (test()) return true; await new Promise((resolve) => setTimeout(resolve, 30)); }
  return !!test();
}
function type(field: HTMLInputElement | HTMLTextAreaElement, value: string) {
  Object.getOwnPropertyDescriptor(field instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, "value")!.set!.call(field, value);
  field.dispatchEvent(new Event("input", { bubbles: true }));
}

/** Walks through the real teaching UI while proving that practice changes no Ledger records. */
export async function ledgerLearningSelfTest(host: HTMLElement, backend: DemoLedgerBackend) {
  const $ = <T extends Element = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const button = (scope: string, label: string) => [...host.querySelectorAll<HTMLButtonElement>(`${scope} button`)].find((item) => item.textContent?.trim() === t(label));
  const next = () => $<HTMLButtonElement>("[data-learning-next]")!;
  const close = () => $<HTMLButtonElement>(`.ledger-learning-head button[aria-label="${t("Close")}"]`)!.click();
  const stored = () => settings.get<Record<string, unknown>>(LEDGER_LEARNING_SETTING, {});
  settings.set(LEDGER_LEARNING_SETTING, undefined);
  const before = JSON.stringify(backend.world);
  const tracking = settings.get("ledgerTrackAgents", false);
  ensure(!$(".ledger-learning"), "The tutorial must not open automatically");
  button(".ledger-toolbar", "Learn Ledger")!.click();
  ensure(await until(() => $(`.ledger-learning [data-learning-step="concepts"]`)), "Learn Ledger did not open the tutorial");
  ensure($(".ledger-learning")?.closest("[role='dialog']")?.getAttribute("aria-modal") === "true", "The tutorial must identify its modal dialog");
  ensure($<HTMLButtonElement>(".ledger-learning-footer button:nth-last-child(2)")?.disabled, "The first step must not go Back");
  next().click();
  ensure(await until(() => $(`[data-learning-step="views"]`)), "Next did not open the view guide");
  button(".ledger-learning-views", "Graph")!.click();
  ensure(await until(() => button(".ledger-learning-views", "Graph")?.getAttribute("aria-pressed") === "true"), "The practice view cards must respond locally");
  next().click();
  ensure(await until(() => $(`[data-learning-step="answer"] textarea`)), "The answer practice did not show the production answer form");
  ensure(next().disabled, "An unanswered practice must block Next");
  const field = $<HTMLTextAreaElement>(".ledger-learning textarea")!;
  field.focus();
  const tab = new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
  field.dispatchEvent(tab);
  ensure(tab.defaultPrevented && await until(() => field.value === t("Stable")), "The practice must use real editable Tab completion");
  ensure(next().disabled && stored().answerSent !== true, "Filling a suggestion must not complete or send the practice answer");
  type(field, "Stable, after the checks.");
  button(".ledger-learning", "Send answer")!.click();
  ensure(await until(() => !next().disabled && stored().answerSent === true), "Only explicit Send must complete the answer practice");
  ensure(!JSON.stringify(stored()).includes("after the checks"), "Practice answer text must not be persisted in settings");
  close();
  button(".ledger-toolbar", "Learn Ledger")!.click();
  ensure(await until(() => $(`[data-learning-step="answer"]`) && !next().disabled), "Reopening must resume saved practice progress");
  next().click();
  ensure(await until(() => $(`[data-learning-step="delivery"][data-delivery]`) || $(`[data-learning-step="delivery"] [data-delivery="saved"]`)), "Delivery practice did not start from Saved");
  for (const [label, state] of [["Mark delivered", "delivered"], ["Confirm", "confirmed"], ["Clean up", "archived"]] as const) {
    ensure(next().disabled, "Next must wait for the complete delivery and review practice");
    button(".ledger-learning", label)!.click();
    ensure(await until(() => $(`[data-delivery="${state}"]`)), `The local ${label} practice did not advance`);
  }
  ensure(!next().disabled, "Archiving the practice must enable Next");
  next().click();
  ensure(await until(() => $(`[data-learning-step="connect"]`)), "The final step must explain connection setup");
  ensure(button(".ledger-learning", "Connect agents") && button(".ledger-learning", "Bring a ChatGPT draft…"), "The final step must offer explicit setup routes");
  next().click();
  ensure(await until(() => !$(".ledger-learning") && stored().completed === true), "Done must save completion without a Ledger write");
  ensure(JSON.stringify(backend.world) === before && settings.get("ledgerTrackAgents", false) === tracking, "Tutorial practice must not change Ledger records or enable agent tracking");

  button(".ledger-toolbar", "Learn Ledger")!.click();
  ensure(await until(() => $(`[data-learning-step="connect"]`)), "Completed tutorials must stay replayable");
  const tutorialTab = button(".ledger-learning-tabs", "Tutorial")!;
  tutorialTab.focus();
  tutorialTab.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true }));
  ensure(await until(() => button(".ledger-learning-tabs", "Guide")?.getAttribute("aria-selected") === "true"), "Arrow keys must switch the Tutorial and Guide tabs");
  const search = $<HTMLInputElement>(`.ledger-learning input[aria-label="${t("Search the guide")}"]`)!;
  type(search, "custom multiple");
  ensure(await until(() => $(`[data-guide-topic="answers"]`)), "The usage guide must search practical terms");
  type(search, "missing-[topic");
  ensure(await until(() => $(".ledger-learning")?.textContent?.includes(t("No guide topics match."))), "The guide must explain an empty search");
  button(".ledger-learning", "Clear search")!.click();
  ensure(await until(() => $(".ledger-learning-topics")?.querySelectorAll("button").length === 9), "Clearing guide search must restore every topic");
  button(".ledger-learning-topics", "Privacy")!.click();
  ensure(await until(() => $(`[data-guide-topic="privacy"]`)?.textContent?.includes("ChatGPT")), "The guide must explain explicit manual draft handling and privacy");
  const done = button(".ledger-learning-footer", "Done")!;
  done.focus();
  const wrap = new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
  done.dispatchEvent(wrap);
  ensure(wrap.defaultPrevented && document.activeElement === $(`.ledger-learning-head button[aria-label="${t("Close")}"]`), "Keyboard focus must remain inside the learning dialog");
  button(".ledger-learning-footer", "Restart")!.click();
  ensure(await until(() => $(`[data-learning-step="concepts"]`) && stored().completed === false && stored().answerSent === false), "Restart must reset learning progress and local practice");
  close();
}
