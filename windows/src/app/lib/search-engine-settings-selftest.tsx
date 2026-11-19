import { createRoot } from "react-dom/client";
import { resolveAddress, searchEngineKey } from "@/entities/terminal";
import { settings } from "@/shared/config";
import { ToolsSettings } from "@/widgets/settings";

const pause = () => new Promise((resolve) => setTimeout(resolve, 20));
const until = async (check: () => boolean) => {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (check()) return true;
    await pause();
  }
  return false;
};

/** Settings › Tools: the search engine picker starts on Google, and a change is saved and used by the next search */
export async function searchEngineSettingsSelfTest(): Promise<[boolean, string]> {
  const saved = settings.get<unknown>(searchEngineKey, undefined);
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:560px";
  document.body.append(host);
  const root = createRoot(host);
  const picker = () => Array.from(host.querySelectorAll<HTMLSelectElement>("select")).find((s) => [...s.options].some((o) => o.value === "naver"));
  try {
    settings.set(searchEngineKey, undefined);
    root.render(<ToolsSettings />);
    if (!await until(() => !!picker())) return [false, "The search engine picker did not appear"];
    if (picker()!.value !== "google") return [false, `The picker starts on ${picker()!.value}, not Google`];
    const select = picker()!;
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, "naver");
    select.dispatchEvent(new Event("change", { bubbles: true }));
    if (!await until(() => settings.get<string>(searchEngineKey, "google") === "naver")) return [false, "Choosing Naver was not saved"];
    const address = resolveAddress("git rebase", settings.get<string>(searchEngineKey, "google"));
    if (!address?.startsWith("https://search.naver.com/")) return [false, `A search went to ${address}`];
    return [true, "Google by default; Naver chosen, saved and used"];
  } finally {
    root.unmount();
    host.remove();
    settings.set(searchEngineKey, saved);
  }
}
