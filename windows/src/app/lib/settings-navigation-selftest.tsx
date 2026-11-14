import { useState } from "react";
import { createRoot } from "react-dom/client";
import { SettingsNavigation, type SettingsTab } from "@/widgets/settings";

const pause = () => new Promise((resolve) => setTimeout(resolve, 20));
const until = async (check: () => boolean) => {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (check()) return true;
    await pause();
  }
  return false;
};

function NavigationFixture() {
  const [tab, setTab] = useState<SettingsTab>("appearance");
  return <SettingsNavigation value={tab} onChange={setTab} />;
}

/** Exercises category selection and layout without loading account or credential panels. */
export async function settingsNavigationSelfTest(): Promise<[boolean, string]> {
  const previousFocus = document.activeElement;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:600px";
  document.body.append(host);
  const root = createRoot(host);
  try {
    root.render(<NavigationFixture />);
    if (!await until(() => host.querySelectorAll("button").length === 7)) return [false, "Settings categories did not mount"];
    const buttons = Array.from(host.querySelectorAll<HTMLButtonElement>("button"));
    if (buttons[5].getAttribute("aria-current") !== "page") return [false, "Initial settings category was lost"];
    for (const width of [600, 320]) {
      host.style.width = `${width}px`;
      for (const button of buttons) {
        const icon = button.querySelector("svg");
        if (!button.textContent?.trim() || icon?.getAttribute("aria-hidden") !== "true") return [false, "Category needs a text label and decorative icon"];
        button.focus();
        if (document.activeElement !== button) return [false, "Category cannot receive keyboard focus"];
        button.click();
        if (!await until(() => button.getAttribute("aria-current") === "page")) return [false, "Category selection did not update"];
        if (host.querySelectorAll('[aria-current="page"]').length !== 1) return [false, "Multiple categories appear selected"];
        if (button.scrollWidth > button.clientWidth + 1) return [false, `Category label overflows at ${width}px`];
      }
      const navigation = host.querySelector<HTMLElement>("nav")!;
      if (navigation.scrollWidth > navigation.clientWidth + 1) return [false, `Navigation overflows at ${width}px`];
    }
    return [true, "Seven labeled categories: initial selection, switching, keyboard focus and narrow layout"];
  } finally {
    root.unmount();
    host.remove();
    if (previousFocus instanceof HTMLElement) previousFocus.focus();
  }
}
