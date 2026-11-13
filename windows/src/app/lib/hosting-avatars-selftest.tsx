import { createRoot } from "react-dom/client";
import { settings } from "@/shared/config";
import { Avatar } from "@/shared/ui";

const until = async (test: () => boolean) => {
  const end = Date.now() + 2500;
  while (Date.now() < end) {
    if (test()) return true;
    await new Promise<void>(resolve => setTimeout(resolve, 20));
  }
  return false;
};

/** A replaced profile retries its new image and obeys the photo setting without network or saved settings. */
export async function hostingAvatarsSelfTest(): Promise<[boolean, string]> {
  const original = settings.get;
  let enabled = true;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0";
  document.body.append(host);
  const root = createRoot(host);
  const first = "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><rect width='24' height='24' fill='red'/></svg>";
  const second = first.replace("red", "green");
  const render = (url: string) => root.render(<Avatar name="Fixture" email="fixture@example.com" url={url} size={24}/>);
  try {
    settings.get = <T,>(key: string, fallback: T): T => key === "avatarFetch" ? enabled as T : original.call(settings, key, fallback) as T;
    render(first);
    if (!await until(() => host.querySelector("img")?.getAttribute("src") === first)) return [false, "The profile photo did not render"];
    host.querySelector("img")!.dispatchEvent(new Event("error"));
    if (!await until(() => !host.querySelector("img") && host.textContent === "F")) return [false, "A failed image did not fall back to the initial"];
    render(second);
    if (!await until(() => host.querySelector("img")?.getAttribute("src") === second)) return [false, "The replacement photo stayed blocked by the previous image failure"];
    enabled = false;
    (settings as unknown as { emit(): void }).emit();
    if (!await until(() => !host.querySelector("img") && host.textContent === "F")) return [false, "The disabled photo setting did not update the avatar"];
    return [true, "Failed photo falls back; replacement photo recovers; disabling photos redraws the initial"];
  } finally {
    root.unmount();
    host.remove();
    settings.get = original;
  }
}
