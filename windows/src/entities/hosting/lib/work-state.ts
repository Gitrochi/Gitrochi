import { language, t } from "@/shared/i18n";

/**
 * An issue or pull/merge request state as a word for display: open, closed or merged, capitalised for the
 * screen language; any other state as the server sent it. The keys are the lowercase state words, not the
 * "Open" button verb. (macOS: WorkState.title)
 */
export function workStateTitle(state: string): string {
  const key = state === "open" || state === "opened" ? "open" : state === "closed" ? "closed" : state === "merged" ? "merged" : null;
  if (!key) return state;
  const [first = "", ...rest] = t(key);
  return first.toLocaleUpperCase(language) + rest.join("");
}
