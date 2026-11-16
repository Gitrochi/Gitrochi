import { createRoot } from "react-dom/client";
import { emptyStatus, type FileChange } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { Inspector } from "@/widgets/inspector";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const frames = () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
const until = async (done: () => boolean, ms = 2500) => {
  const end = Date.now() + ms;
  while (!done() && Date.now() < end) await pause(20);
  return done();
};

/**
 * The working changes as the board draws them: the header as tall as the graph's, Unstaged and Staged with their count
 * pills and text buttons, the shared 28px file row (badge letters, rename, binary, the stage button on hover or focus
 * only, the name never cut in a 280px panel), the composer (one Summary field with its count out of 72, the folded
 * description, AI message, one filled Commit that says why it is disabled), the clean state and the operation banner.
 */
export async function workingChangesSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, run: ipc.run, http: ipc.http };
  const memory = new Map<string, unknown>([["avatarFetch", false], ["fileViewMode", "list"]]);
  const unexpected: string[] = [], staged: string[] = [], unstaged: string[] = [];
  let commits = 0, writes = 0;
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: "340px", height: "900px", display: "flex", visibility: "hidden" });
  document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const change = (path: string, kind: FileChange["kind"], isStaged = false, oldPath: string | null = null): FileChange => ({ path, oldPath, kind, staged: isStaged });
  const all = <T extends HTMLElement = HTMLElement>(selector: string) => [...host.querySelectorAll<T>(selector)];
  const one = <T extends HTMLElement = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const row = (name: string) => all(".file-row").find((item) => item.querySelector(".file-row-name > span")?.textContent === name);
  const height = (element: Element | null | undefined) => Math.round(element?.getBoundingClientRect().height ?? -1);
  const failed: string[] = [];
  const check = (ok: unknown, what: string) => { if (!ok) failed.push(what); };
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); store.changed(); };
    ipc.run = async () => { unexpected.push("process"); throw new Error("Fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Fixture blocked network"); };
    store.path = "C:/gitrochi-working-changes-fixture";
    store.selection = { kind: "wip" };
    store.me = { name: "Alex Kim", email: "alex@example.com" };
    store.stage = async (files) => { staged.push(...files.map((file) => file.path)); return true; };
    store.unstage = async (files) => { unstaged.push(...files.map((file) => file.path)); return true; };
    store.commit = async () => { commits++; };
    store.generateCommitMessage = async () => { writes++; };
    const long = "macos/Sources/Views/Search/AnExtremelyLongSwiftFileNameForTheNarrowPanel.swift";
    store.status = {
      ...emptyStatus(),
      unstaged: [change("macos/Sources/Views/Search/SearchPanel.swift", "modified"), change("docs/search-tips.md", "untracked"), change("assets/search-empty.png", "added"), change(long, "typeChanged")],
      staged: [change("docs/search.md", "renamed", true, "docs/find.md"), change("docs/copy.md", "copied", true, "docs/find.md")],
    };
    store.unstagedStats = { "macos/Sources/Views/Search/SearchPanel.swift": { added: 12, deleted: 2 }, "docs/search-tips.md": { added: 9, deleted: 0 }, "assets/search-empty.png": { added: null, deleted: null }, [long]: { added: 1, deleted: 1 } };
    store.stagedStats = { "docs/search.md": { added: 2, deleted: 12 }, "docs/copy.md": { added: 0, deleted: 0 } };
    root.render(<Inspector store={store} />);
    if (!await until(() => !!one(".working-changes .working-head") && all(".file-row").length === 6)) return [false, "Working changes did not mount"];
    await frames();

    // the header, the groups and their words
    const head = one(".working-head")!;
    check(height(head) === 35 && one(".working-head h2")?.textContent === t("Uncommitted changes") && getComputedStyle(one(".working-head h2")!).fontSize === "15px", "the header must be 35px with Uncommitted changes at 15px");
    check(one(".working-files-title")?.textContent === t("Changed files") && !!one(`.working-files-head .segmented[aria-label="${t("File list layout")}"]`), "Changed files with the list/tree toggle is missing");
    const sections = all(".working-section-head");
    check(sections.map((section) => section.querySelector(".working-section-title")?.textContent).join("|") === `${t("Unstaged")}|${t("Staged")}`, "the groups must be Unstaged and Staged");
    check(sections.map((section) => section.querySelector(".status-pill")?.textContent).join("|") === "4|2" && sections.every((section) => height(section) === 28), "each group needs its count pill in a 28px head");
    check(sections.map((section) => section.querySelector(".hosted-text-button")?.textContent).join("|") === `${t("Stage all")}|${t("Unstage all")}`, "Stage all and Unstage all must be text buttons");
    check(!one(".working-changes .card") && !one(".section-dot") && !one(".gitch-bar") && !one(".commit-impact"), "the panel is flat: no cards, dots, gitch bar or impact card");

    // the shared row: 28px, 8px sides, radius 6, the 18px badge with the board's letters
    const first = row("SearchPanel.swift")!, style = getComputedStyle(first);
    check(height(first) === 28 && style.paddingLeft === "8px" && style.paddingRight === "8px" && style.borderRadius === "6px", "a file row must be 28px with 8px sides and a 6px radius");
    const badge = first.querySelector<HTMLElement>(".status-badge")!, badgeStyle = getComputedStyle(badge);
    check(Math.round(badge.getBoundingClientRect().width) === 18 && height(badge) === 18 && badgeStyle.borderRadius === "4px" && badgeStyle.fontSize === "11px" && badgeStyle.fontWeight === "600" && badgeStyle.borderTopWidth === "0px", "the status badge must be 18px, radius 4, 11px semibold, no border");
    const letters = Object.fromEntries(all(".file-row").map((item) => [item.querySelector(".file-row-name > span")!.textContent, item.querySelector(".status-badge")!.textContent]));
    check(letters["SearchPanel.swift"] === "M" && letters["search-tips.md"] === "U" && letters["search-empty.png"] === "A" && letters["search.md"] === "R" && letters["copy.md"] === "R" && letters[long.split("/").pop()!] === "M", `badge letters: ${JSON.stringify(letters)}`);
    check(first.querySelector(".file-row-folder")?.textContent === "macos/Sources/Views/Search" || first.querySelector(".file-row-folder")?.textContent?.startsWith("…/"), "the folder must be whole or shortened by whole segments");
    check(first.querySelector(".linestat")?.textContent === "+12−2" && row("search-tips.md")?.querySelector(".linestat .z")?.textContent === "−0", "the counts show both sides, the empty one in grey");
    check(row("search-empty.png")?.querySelector(".status-pill")?.textContent === t("Binary") && !row("search-empty.png")?.querySelector(".linestat"), "a binary file has the neutral pill in place of the counts");
    check(row("search.md")?.querySelector(".file-row-rename")?.textContent === "find.md → search.md" && row("copy.md")?.querySelector(".file-row-rename")?.textContent === t("copied from {0}", "find.md"), "a rename reads old → new and a copy reads copied from");

    // the row's own action: on hover or keyboard focus only
    check(!one(".file-row .file-row-act"), "no stage button may show before a row is hovered or focused");
    first.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    check(await until(() => first.querySelector(".file-row-act")?.getAttribute("aria-label") === t("Stage")), "hover did not show the stage button");
    const act = first.querySelector<HTMLElement>(".file-row-act")!;
    check(Math.round(act.getBoundingClientRect().width) === 24 && height(act) === 24, "the stage button must be a 24px target");
    act.click();
    check(staged.join() === "macos/Sources/Views/Search/SearchPanel.swift" && store.diffSource == null, "the stage button must stage its file without opening it");
    first.dispatchEvent(new MouseEvent("mouseout", { bubbles: true, relatedTarget: host }));
    check(await until(() => !first.querySelector(".file-row-act")), "the stage button stayed after the pointer left");
    const renamed = row("search.md")!;
    // the fixture is not visible, so it cannot take real focus: the events say what focus would
    renamed.querySelector<HTMLButtonElement>(".file-row-open")!.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
    check(await until(() => renamed.querySelector(".file-row-act")?.getAttribute("aria-label") === t("Unstage")), "keyboard focus did not show the unstage button");
    renamed.querySelector<HTMLButtonElement>(".file-row-open")!.dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
    check(unstaged.join() === "docs/search.md", "Space on a focused row must unstage it");
    renamed.querySelector<HTMLButtonElement>(".file-row-open")!.dispatchEvent(new FocusEvent("focusout", { bubbles: true, relatedTarget: host }));
    check(await until(() => !renamed.querySelector(".file-row-act")), "the unstage button stayed after focus left");

    // nothing is cut at the panel's widths: the folder and the counts give way, the name stays whole
    for (const width of [280, 340]) {
      host.style.width = `${width}px`;
      await frames(); await pause(60); await frames();
      const bounds = host.getBoundingClientRect();
      const inside = all(".working-head > *, .working-section-head > *:not(.spacer), .file-row, .composer > *").every((element) => { const rect = element.getBoundingClientRect(); return rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1; });
      const names = all(".file-row").filter((item) => item !== row(long.split("/").pop()!)).every((item) => { const name = item.querySelector<HTMLElement>(".file-row-name")!; return !name.classList.contains("cut") && name.scrollWidth <= name.clientWidth + 1; });
      const words = all<HTMLElement>(".file-row-open").every((item) => item.scrollWidth <= item.clientWidth + 1);
      check(inside && names && words, `at ${width}px something left the panel or a name was cut (inside=${inside} names=${names} words=${words})`);
    }
    // a name wider than the row itself is the only thing that is ever cut, after its folder and counts have gone
    const longRow = row(long.split("/").pop()!)!;
    host.style.width = "280px";
    check(await until(() => longRow.querySelector(".file-row-name")!.classList.contains("cut") && !longRow.querySelector(".file-row-folder") && !longRow.querySelector(".linestat")), "a name wider than the row must lose its folder and counts before it is cut");
    host.style.width = "340px";
    await frames();

    // selection is the tint alone, with the name in semibold
    store.diffSource = { kind: "working", change: store.status.unstaged[0] };
    store.changed();
    check(await until(() => first.classList.contains("selected")) && getComputedStyle(first.querySelector(".file-row-name")!).fontWeight === "600" && getComputedStyle(first).borderTopWidth === "0px" && getComputedStyle(first).boxShadow === "none"
      && all(".file-row.selected").length === 1, "the selected row must be one tint with a semibold name and no border");

    // the composer
    const field = one<HTMLInputElement>(".composer-field input")!, count = () => one(".composer-count");
    const commit = () => one<HTMLButtonElement>(".composer-commit")!;
    check(one(".composer-name")?.textContent === "Alex Kim" && one(".composer-email")?.textContent === "· alex@example.com" && height(one(".composer-identity")) <= 22, "the committer must be one line: avatar, name, email");
    check(all(".composer input, .composer textarea").length === 1 && height(one(".composer-field")) === 28 && field.placeholder === t("Summary") && count()?.textContent === "0/72", "the composer must be one 28px Summary field with its count out of 72");
    check(one(".composer-disclosure")?.getAttribute("aria-expanded") === "false" && one(".composer-disclosure")?.textContent === t("Description (optional)"), "the description must start folded");
    check(one(".composer-ai")?.textContent === t("AI message") && all(".composer .btn").length === 1 && all(".composer .btn.primary").length === 1, "AI message is a text button and Commit the one filled button");
    check(commit().textContent === t("Commit {0} files", 2) + "Ctrl+Enter" || commit().textContent?.startsWith(t("Commit {0} files", 2)), "Commit must count the staged files and show its shortcut");
    check(commit().disabled && one(".composer .disabled-reason-text")?.textContent === t("Write a summary to enable commit."), "a disabled Commit must say why beside it");
    store.setSummary("Document the restored search state");
    check(await until(() => !commit().disabled && count()?.textContent === "34/72" && !count()!.classList.contains("over") && !one(".composer .disabled-reason-text")), "typing a summary did not enable Commit or count 34/72");
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true, cancelable: true }));
    check(commits === 1, "Ctrl+Enter in the Summary field must commit");
    store.setSummary("x".repeat(80));
    check(await until(() => count()?.textContent === "80/72" && count()!.classList.contains("over")), "a summary past 72 must mark its count");
    one<HTMLButtonElement>(".composer-disclosure")!.click();
    check(await until(() => !!one(".composer-description") && one(".composer-disclosure")?.getAttribute("aria-expanded") === "true"), "the description did not unfold");
    one<HTMLButtonElement>(".composer-disclosure")!.click();
    await until(() => !one(".composer-description"));
    // while a commit runs, Commit waits and says what is running
    store.busy = "Fixture commit";
    store.changed();
    check(await until(() => commit().disabled && one(".composer .disabled-reason-text")?.textContent === "Fixture commit"), "a running command must disable Commit and name itself");
    store.busy = null;
    // the AI message failed: the shared failure block, with Retry
    store.commitMessageFailure = "Fixture failure";
    store.changed();
    check(await until(() => one(".composer .failure-block")?.getAttribute("role") === "alert" && !!one(".composer .failure-block")?.textContent?.includes(t("Couldn't write the commit message"))), "an AI failure must show the shared failure block in the composer");
    [...host.querySelectorAll<HTMLButtonElement>(".composer .failure-block button")].find((item) => item.textContent === t("Retry"))?.click();
    check(writes === 1, "Retry must write the message again");
    store.commitMessageFailure = null;
    store.setSummary("");

    // conflicts and an operation in progress: a white banner with a border, Mark as resolved on the row, Continue filled
    store.repoState = "merging";
    store.status = { ...store.status, conflicted: [change("windows/tests/search-state.test.ts", "conflicted")] };
    store.changed();
    check(await until(() => !!one(".operation-banner") && row("search-state.test.ts")?.querySelector(".status-badge")?.textContent === "C"), "the conflict did not show");
    const banner = one(".operation-banner")!, bannerStyle = getComputedStyle(banner);
    check(bannerStyle.borderTopWidth === "1px" && bannerStyle.backgroundColor === getComputedStyle(one(".working-changes")!).backgroundColor, "the banner must be white with a 1px border, not tinted");
    const bannerButtons = [...banner.querySelectorAll<HTMLButtonElement>("button")];
    check(bannerButtons.map((item) => item.textContent).join("|") === `${t("Abort…")}|${t("Continue")}` && bannerButtons[1].disabled, "the banner must offer Abort… and a Continue that waits for the conflicts");
    check(row("search-state.test.ts")?.querySelector(".file-row-text-action")?.textContent === t("Mark as resolved") && all(".working-section-title")[0]?.textContent === t("Conflicted"), "a conflicted row must offer Mark as resolved");
    check(host.querySelectorAll(".working-changes .btn.primary").length === 1 && !commit().classList.contains("primary"), "one filled button: Continue, while an operation is in progress");
    row("search-state.test.ts")!.querySelector<HTMLButtonElement>(".file-row-text-action")!.click();
    check(staged.at(-1) === "windows/tests/search-state.test.ts", "Mark as resolved must stage the file");

    // a clean tree: the empty state, with the composer still there
    store.repoState = "clean";
    store.status = emptyStatus();
    store.diffSource = null;
    store.changed();
    check(await until(() => one(".working-changes .hosted-empty-title")?.textContent === t("Working directory is clean")) && !one(".working-changes .card") && !one(".working-files-head") && !!one(".composer"), "a clean tree must be the empty state");
    check(commit().disabled && one(".composer .disabled-reason-text")?.textContent === t("Stage the files you want to include.") && commit().textContent?.startsWith(t("Commit")), "with nothing staged Commit must say to stage files");

    return [failed.length === 0 && unexpected.length === 0, failed.length || unexpected.length ? JSON.stringify({ failed, unexpected }) : "Header, groups, the shared file row (badge, rename, binary, hover and focus action, fold order at 280 and 340), selection, composer (count, 72, description, Ctrl+Enter, disabled reason, AI failure), conflict banner and clean state rendered"];
  } finally {
    root.unmount(); await pause(20); host.remove();
    settings.get = original.get; settings.set = original.set; ipc.run = original.run; ipc.http = original.http;
  }
}
