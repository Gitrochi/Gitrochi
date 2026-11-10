import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Toolbar } from "@/widgets/toolbar";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 60));

/** The toolbar by page (docs/design.md › App shell): repository pages get the Git actions, other pages More and the terminal, no repository only the account. */
export async function toolbarSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  host.hidden = true;
  document.body.append(host);
  const root = createRoot(host);
  const store = new RepoStore();
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const labels = () => [...host.querySelectorAll<HTMLButtonElement>(".toolbar button")].map((b) => b.getAttribute("aria-label") ?? b.textContent?.trim() ?? "");
  const has = (text: string) => labels().some((label) => label.includes(text));
  const show = async () => { root.render(<Toolbar store={store} />); await pause(); };
  try {
    await show();
    check(!has(t("More")) && !has(t("Terminal")) && !has("Fetch"), `Without a repository only the account belongs in the toolbar: ${labels().join(" | ")}`);

    store.path = "C:/fixture/repo";
    store.headBranch = "topic";
    store.headHash = "a".repeat(40);
    store.status = { ...store.status, upstream: "origin/topic", ahead: 2, behind: 0 };
    store.destination = "repository";
    await show();
    for (const label of [t("Changes"), "Fetch", "Pull", "Push", t("More"), t("Terminal")])
      check(has(label), `The repository toolbar is missing ${label}: ${labels().join(" | ")}`);
    check(!labels().some((label) => label === t("Undo")), "Undo moved into More; it has no toolbar button");
    check(host.querySelector(".tool-group.prominent")?.textContent?.includes("Push"), "With only commits to push, Push is the one prominent item");
    check(!/↑|↓/.test([...host.querySelectorAll(".tool")].map((b) => b.textContent).join("")), "Ahead/behind counts live in the title, not on the buttons");

    host.querySelector<HTMLButtonElement>(`.toolbar button[aria-label="${t("More")}"]`)!.click();
    await pause();
    const items = [...document.querySelectorAll(".menu .menu-item")].map((item) => item.textContent ?? "");
    check(items[0]?.startsWith("Fetch") && items[1]?.startsWith("Pull") && items[2]?.startsWith("Push") && items[3]?.startsWith(t("Undo")), `More must start with Fetch, Pull, Push and Undo: ${items.join(" | ")}`);
    document.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    await pause();

    store.status = { ...store.status, ahead: 2, behind: 3 };
    await show();
    check(!host.querySelector(".tool-group.prominent"), "A diverged branch has no prominent sync action");

    store.destination = "issues";
    await show();
    check(has(t("More")) && has(t("Terminal")) && !has("Fetch") && !has(t("Changes")), `Other pages show More and the terminal only: ${labels().join(" | ")}`);
    return [true, "no repository · repository · other page; More order; prominent Push"];
  } finally {
    root.unmount();
    host.remove();
  }
}
