import { createRoot } from "react-dom/client";
import type { Branch, WorkspaceDestination } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { WorkspaceContent } from "@/pages/repo";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 30));
async function until(test: () => boolean) {
  const end = Date.now() + 3500;
  while (Date.now() < end) { if (test()) return true; await pause(); }
  return test();
}

type Page = "pullRequests" | "issues" | "actions" | "releases";
type Outcome = "data" | "empty";
const wide = 1100, narrow = 600;

/**
 * The summary card of Pull requests, Issues, Actions and Releases is there from the first frame, 112 px tall in a wide
 * window and a 44 px strip in a narrow one, loading until its data arrives; what arrives (something, or nothing to
 * report) changes its words but not its height, so the list below never moves.
 */
export async function summaryCardSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: `${wide}px`, height: "700px", display: "flex", flexDirection: "column", visibility: "hidden" });
  document.body.append(host);
  let root = createRoot(host);
  const original = { http: ipc.http, run: ipc.run, token: accounts.token, accounts: accounts.accounts };
  const profile = { id: "summary-fixture", provider: "github" as const, server: "https://github.com", username: "fixture", name: null, avatarURL: null };
  const issue = { number: 7, title: "Fixture issue", body: "Fixture body", state: "open", html_url: "https://github.com/fixture/repo/issues/7", user: { login: "fixture" }, comments: 0, assignees: [{ login: "fixture" }], labels: [] };
  const request = { number: 1, title: "Fixture pull request", body: "Details", user: { login: "fixture" }, requested_reviewers: [], head: { ref: "topic", sha: "a".repeat(40), repo: { full_name: "fixture/repo" } }, base: { ref: "main" }, html_url: "https://github.com/fixture/repo/pull/1", state: "open" };
  const release = { id: 3, name: "Fixture release", tag_name: "v1.0", body: "Notes", draft: false, html_url: "https://github.com/fixture/repo/releases/tag/v1.0", assets: [] };
  const branch = (name: string): Branch => ({ name, target: "a".repeat(40), upstream: null, ahead: 0, behind: 0, upstreamGone: false, isCurrent: name !== "main", isRemote: false });
  const captions: Record<Page, string> = { pullRequests: "Loading pull requests…", issues: "Loading issues…", actions: "Loading runs…", releases: "Loading releases…" };
  const nothing: Record<Page, string> = { pullRequests: "No pull request to open from here", issues: "No open issues are assigned to you", actions: "No runs on this branch yet", releases: "No releases yet" };
  const pictures: Record<Page, string> = { pullRequests: ".pr-track", issues: ".issue-bar", actions: ".ci-track", releases: ".release-track" };
  const checked: string[] = [];
  const stores: RepoStore[] = [];
  try {
    accounts.accounts = [profile];
    accounts.token = async () => "fixture-token";
    // the counts the cards read from the clone: nothing incoming, three commits of its own
    ipc.run = async (_program, args) => ({ status: 0, stdout: args.includes("--left-right") ? "0\t3" : args.includes("--count") ? "3" : "", stderr: "" });
    for (const page of ["pullRequests", "issues", "actions", "releases"] as Page[]) {
      for (const outcome of ["data", "empty"] as Outcome[]) {
        const name = `${page}/${outcome}`, empty = outcome === "empty";
        let arrive = () => {};
        const arrived = new Promise<void>((resolve) => { arrive = resolve; });
        const store = new RepoStore();
        stores.push(store);
        store.path = "C:/fixture/repo";
        store.target = { provider: "github", host: "github.com", remote: "origin", path: "fixture/repo" };
        // on the base branch there is no request to open: the pull request card's empty state
        store.headBranch = page === "pullRequests" && empty ? "main" : "topic";
        store.headHash = "a".repeat(40);
        store.localBranches = [branch("main"), branch("topic")];
        store.destination = page as WorkspaceDestination;
        Object.defineProperty(store, "hostingAccount", { get: () => profile });
        store.ci.loadJobs = async () => {};
        store.ci.load = async () => {
          store.ci.state = { kind: "loading" }; store.changed();
          await arrived;
          store.ci.pipelines = empty ? [] : [{ id: 1, number: 12, name: "CI", title: "Fixture run", ref: "topic", sha: "a".repeat(40), status: "success", url: "https://github.com/fixture/repo/actions/runs/1", created: null, event: "push", actor: "fixture" }];
          store.ci.state = { kind: "loaded" }; store.changed();
        };
        ipc.http = async (method, url) => {
          if (method !== "GET") throw new Error(`Unexpected write: ${method} ${url}`);
          const list = url.includes("/pulls?") ? [request] : url.includes("/releases?") ? [release] : url.includes("/issues?") && !url.includes("/search/") ? [issue] : null;
          if (list) { await arrived; return { status: 200, body: JSON.stringify(empty ? [] : list) }; }
          if (url.endsWith("/pulls/1")) return { status: 200, body: JSON.stringify(request) };
          if (url.includes("/search/issues?")) return { status: 200, body: JSON.stringify({ items: [], total_count: 0 }) };
          if (url.includes("/releases/")) return { status: 200, body: JSON.stringify(release) };
          return { status: 200, body: "[]" };
        };
        const card = () => host.querySelector<HTMLElement>(".hosted-summary"), strip = () => host.querySelector<HTMLElement>(".hosted-strip");
        const below = () => host.querySelector<HTMLElement>(".hosted-columns, .pr-page-split");
        const measure = () => ({ card: card()!.getBoundingClientRect().height, strip: strip()!.getBoundingClientRect().height, below: below()!.getBoundingClientRect().top - host.getBoundingClientRect().top });
        const resize = async (width: number) => { host.style.width = `${width}px`; await pause(); };
        const fail = (message: string): [boolean, string] => [false, `${name}: ${message}`];

        await resize(wide);
        root.render(<WorkspaceContent store={store} openSettings={() => {}} />);
        // the card and the list are there before any data
        if (!await until(() => !!card() && !!strip() && !!below())) return fail("the page did not mount with its summary card");
        if (!card()!.querySelector(".hosted-summary-bars") || !card()!.querySelector(".hosted-summary-trail .hosted-summary-bar")) return fail("the loading card must draw its grey bars");
        if (!card()!.querySelector(".hosted-summary-loading")?.textContent?.includes(t(captions[page]))) return fail(`the loading card must say "${captions[page]}"`);
        const before = measure();
        if (before.card !== 112 || before.strip !== 0) return fail(`the loading card must be 112 px tall in a wide window: ${JSON.stringify(before)}`);
        await resize(narrow);
        const beforeNarrow = measure();
        if (beforeNarrow.strip !== 44 || beforeNarrow.card !== 0) return fail(`the loading strip must be 44 px tall in a narrow window: ${JSON.stringify(beforeNarrow)}`);
        if (!strip()!.querySelector(".spinner") || !strip()!.textContent?.includes(t(captions[page]))) return fail("the loading strip must show its spinner and caption");

        await resize(wide);
        arrive();
        if (!await until(() => !!card() && !card()!.querySelector(".hosted-summary-bars") && !card()!.querySelector(".hosted-summary-loading"))) return fail("the card kept loading after its data arrived");
        const words = empty ? t(nothing[page]) : "";
        if (empty ? !card()!.textContent?.includes(words) || !!card()!.querySelector(pictures[page]) : !await until(() => !!card()?.querySelector(pictures[page])))
          return fail(empty ? `the empty card must say "${nothing[page]}" and draw no picture: ${card()!.textContent}` : `the card did not draw ${pictures[page]}: ${card()!.textContent}`);
        const after = measure();
        if (after.card !== 112 || after.below !== before.below) return fail(`the card changed height or the list moved when the data arrived: ${JSON.stringify(before)} → ${JSON.stringify(after)}`);
        await resize(narrow);
        const afterNarrow = measure();
        if (afterNarrow.strip !== 44 || afterNarrow.below !== beforeNarrow.below) return fail(`the strip changed height or the list moved when the data arrived: ${JSON.stringify(beforeNarrow)} → ${JSON.stringify(afterNarrow)}`);
        if (empty && !strip()!.textContent?.includes(words)) return fail(`the empty strip must say "${nothing[page]}": ${strip()!.textContent}`);
        checked.push(name);
        root.unmount(); host.replaceChildren(); root = createRoot(host);
      }
    }
    return [true, `card 112 px and strip 44 px before and after the data, list top unmoved: ${checked.join(", ")}`];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally {
    root.unmount();
    host.remove();
    ipc.http = original.http;
    ipc.run = original.run;
    accounts.token = original.token;
    accounts.accounts = original.accounts;
    for (const store of stores) store.ci.reset();
  }
}
