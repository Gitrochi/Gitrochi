import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { AccountQuickControls } from "@/widgets/toolbar";
import { type HostAccount } from "@/entities/git";
import { gitch, type GitchBrowserLogin, type GitHubLoginCapability } from "@/entities/gitch";
import { type AccountStatus, accounts } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (check: () => boolean) => { for (let attempt = 0; attempt < 125; attempt++) { if (check()) return true; await sleep(20); } return false; };
const popover = () => document.querySelector<HTMLElement>(".account-quick-popover");
const inPopover = (label: string) => Array.from(popover()?.querySelectorAll<HTMLButtonElement>("button") ?? []).find((item) => item.textContent?.trim() === t(label));
const menuItem = (label: string) => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.querySelector(".label")?.textContent === label);
const drawing = (root: ParentNode, status: string) => root.querySelector(`[data-status="${status}"] svg`)?.innerHTML ?? "";

/** The account button and its popover, without touching real accounts or sign-in: photo and badge, the reason, Change…, the three state drawings. */
export async function accountQuickControlsSelfTest(): Promise<[boolean, string]> {
  const original = { accounts: accounts.accounts, accountFor: accounts.accountFor, preferredID: accounts.preferredID, status: accounts.status, start: gitch.startBrowserLogin, state: gitch.browserLoginStatus, cancel: gitch.cancelBrowserLogin };
  const host = document.createElement("div"); document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const alice: HostAccount = { id: "quick-alice", provider: "github", server: "https://github.com", username: "alice", name: "Alice", avatarURL: null };
  const bob: HostAccount = { ...alice, id: "quick-bob", username: "bob-with-a-long-account-name-for-narrow-rows", name: "Bob" };
  let active = alice, chosen: string | null = null, selections = 0, starts = 0, refreshes = 0;
  let states: Record<string, AccountStatus> = {};
  let requested: { capability?: GitHubLoginCapability; login?: string } | null = null;
  const flow: GitchBrowserLogin = { schemaVersion: 1, session: "github-quickQA123", state: "pending", phase: "queued", deviceCode: null, verificationURL: "https://github.com/login/device", login: null, email: null, message: "Fake sign-in only" };
  const trigger = () => host.querySelector<HTMLButtonElement>(".account-quick-trigger");
  try {
    accounts.accounts = [alice, bob]; accounts.accountFor = () => active; accounts.preferredID = () => chosen; accounts.status = (account) => states[account.id] ?? "signedIn";
    store.path = "/fixture/quick-accounts"; store.target = { provider: "github", host: "github.com", path: "owner/repository", remote: "origin" };
    store.me = { name: "Git Author", email: "author@example.invalid" };
    store.gitchStatus = { inRepo: true, lockedAccount: "locked-git-user", account: "locked-git-user", accountSource: "lock", pushAccount: "locked-git-user", ignored: false };
    store.useAccount = (account) => { active = account; chosen = account.id; selections++; store.changed(); };
    store.refreshGitch = async () => { refreshes++; };
    gitch.startBrowserLogin = async (capability, login) => { starts++; requested = { capability, login }; return flow; };
    gitch.browserLoginStatus = async () => flow; gitch.cancelBrowserLogin = async () => ({ ...flow, state: "cancelled" });
    root.render(createElement(AccountQuickControls, { store }));
    if (!await until(() => !!trigger())) return [false, "The account button is missing"];

    // the button is the 24px photo alone (an initial without one), with no badge while the account is signed in
    const photo = trigger()!.querySelector<HTMLElement>(".avatar");
    if (!photo || photo.textContent !== "A" || Math.round(photo.getBoundingClientRect().width) !== 24 || trigger()!.textContent !== "A") return [false, `The button must show only the 24px photo: ${trigger()!.textContent}`];
    if (trigger()!.querySelector(".account-quick-badge")) return [false, "A signed-in repository account must not show the warning badge"];

    trigger()!.click();
    if (!await until(() => !!inPopover("Change…"))) return [false, "The account popover did not open"];
    const text = () => popover()!.textContent ?? "";
    if (!text().includes(t("This repository")) || !text().includes("@alice") || !text().includes(t("First account on {0}", "github.com"))) return [false, `This repository's account or the reason it was chosen is missing: ${text()}`];
    if (!text().includes("Git Author") || !text().includes("author@example.invalid") || !text().includes(t("Locked by this repository's rules")) || !popover()!.querySelector('[data-status="locked"]')) return [false, "The Git identity or its lock is missing"];
    if (!text().includes(t("Other accounts")) || !text().includes(`${t("Signed in")} · GitHub`) || !inPopover("Inbox") || !inPopover("Add account…") || !inPopover("Manage accounts…")) return [false, "The other accounts or the popover's actions are missing"];
    if (text().includes(t("Remove account…")) || text().includes(t("Disconnect"))) return [false, "Accounts are removed only in Settings"];

    // the Git account and its rules can be read again from where they are shown
    inPopover("Change…")!.click();
    if (!await until(() => !!menuItem(t("Refresh account status")))) return [false, "Refresh account status is missing from the Change… menu"];
    menuItem(t("Refresh account status"))!.click();
    if (!await until(() => refreshes === 1 && !menuItem(t("Refresh account status")))) return [false, "Refresh account status did not read the Git account again"];

    // the board's measures: 360 wide, a 32px photo and a semibold name for this repository, 24px and regular for the others
    const measure = (selector: string) => popover()!.querySelector<HTMLElement>(selector)!;
    const own = measure(`[data-account="${alice.id}"]`), other = measure(`[data-account="${bob.id}"]`);
    if (Math.round(popover()!.getBoundingClientRect().width) !== 360 || !popover()!.querySelector(".account-popover-nub")) return [false, "The popover is 360px wide with its arrow"];
    if (Math.round(own.getBoundingClientRect().height) !== 52 || Math.round(own.querySelector(".avatar")!.getBoundingClientRect().width) !== 32 || getComputedStyle(own.querySelector(".account-popover-name")!).fontWeight !== "600") return [false, "This repository's row is 52px with a 32px photo and a semibold name"];
    if (Math.round(other.querySelector(".avatar")!.getBoundingClientRect().width) !== 24 || getComputedStyle(other.querySelector(".account-popover-name")!).fontWeight === "600") return [false, "Another account's row has a 24px photo and a regular name"];
    if (Math.round(measure(".account-popover-row.identity").getBoundingClientRect().height) !== 48 || Math.round(measure(".account-popover-action").getBoundingClientRect().height) !== 28) return [false, "The identity row is 48px and the actions are 28px"];

    // nothing in the 360px popover is squeezed or clipped, even with a long account name
    const panel = popover()!, box = panel.getBoundingClientRect();
    if (panel.scrollWidth > panel.clientWidth) return [false, `The popover scrolls sideways: ${panel.scrollWidth} > ${panel.clientWidth}`];
    for (const button of panel.querySelectorAll<HTMLElement>("button")) {
      const bounds = button.getBoundingClientRect();
      if (bounds.left < box.left || bounds.right > box.right || button.scrollWidth > button.clientWidth) return [false, `A popover button is clipped: ${button.textContent}`];
    }
    for (const line of panel.querySelectorAll<HTMLElement>(".account-popover-text")) if (line.getBoundingClientRect().width < 120) return [false, `A row's words are squeezed to ${Math.round(line.getBoundingClientRect().width)}px`];
    for (const line of panel.querySelectorAll<HTMLElement>(".account-popover-title, .account-popover-caption")) if (line.scrollWidth > line.clientWidth) return [false, `A row's words are clipped: ${line.textContent}`];

    // Change… picks another account for this repository, and the reason follows
    inPopover("Change…")!.click();
    if (!await until(() => !!menuItem(`@${bob.username} · github.com`))) return [false, "Change… did not list the accounts for this repository"];
    menuItem(`@${bob.username} · github.com`)!.click();
    if (!await until(() => selections === 1 && trigger()?.textContent === "B" && text().includes(t("Chosen for this repository")))) return [false, "Choosing another account did not update the button and the reason"];
    if (store.gitchStatus.lockedAccount !== "locked-git-user" || store.me.name !== "Git Author" || starts !== 0) return [false, "Choosing the hosting account changed the Git identity or started a sign-in"];

    // the badge is for this repository's own account only; each state has its own drawing
    states = { [alice.id]: "needsYourApproval" }; store.changed();
    if (!await until(() => !!popover()?.querySelector(`[data-account="${alice.id}"] [data-status="needsYourApproval"]`))) return [false, "Another account's state is not shown in the popover"];
    if (trigger()!.querySelector(".account-quick-badge")) return [false, "Another account's state must not badge the button"];
    states = { [alice.id]: "needsYourApproval", [bob.id]: "needsApproval" }; store.changed();
    if (!await until(() => !!trigger()?.querySelector(".account-quick-badge"))) return [false, "The repository account's state did not badge the button"];
    const drawings = [drawing(panel, "needsApproval"), drawing(panel, "needsYourApproval"), drawing(panel, "locked")];
    if (drawings.some((value) => !value) || new Set(drawings).size !== 3) return [false, "Needs approval, Needs your approval and Locked must each have their own icon"];
    if (!inPopover("Renew…") || !inPopover("Approve…") || !panel.querySelector(".account-popover-notice")) return [false, "A state must come with the one action that settles it, and the repository's own in the notice above it"];
    for (const line of panel.querySelectorAll<HTMLElement>(".account-popover-text, .notice-block-text")) if (line.getBoundingClientRect().width < 120) return [false, `With states shown, a row's words are squeezed to ${Math.round(line.getBoundingClientRect().width)}px`];
    if (panel.scrollWidth > panel.clientWidth) return [false, "With states shown the popover scrolls sideways"];

    // Renew… opens the browser sign-in for that account and waits for the user
    inPopover("Renew…")!.click();
    const signIn = () => Array.from(document.querySelectorAll<HTMLButtonElement>(".github-sign-in-sheet button")).find((item) => item.textContent?.trim() === t("Sign in to GitHub in browser"));
    if (!await until(() => !!signIn())) return [false, "Renew… did not open the sign-in sheet"];
    if (starts !== 0 || !document.querySelector(".github-sign-in-sheet .shared-sheet-context")?.textContent?.includes(`@${bob.username}`)) return [false, "The sign-in sheet must name the account and wait for the user"];
    signIn()!.click();
    if (!await until(() => starts === 1)) return [false, "The explicit click did not start the sign-in"];
    const captured = requested as { capability?: GitHubLoginCapability; login?: string } | null;
    return [captured?.capability === "standard" && captured.login === bob.username && selections === 1, JSON.stringify({ selections, starts, requested })];
  } finally {
    root.unmount(); await sleep(25); host.remove();
    accounts.accounts = original.accounts; accounts.accountFor = original.accountFor; accounts.preferredID = original.preferredID; accounts.status = original.status;
    gitch.startBrowserLogin = original.start; gitch.browserLoginStatus = original.state; gitch.cancelBrowserLogin = original.cancel;
  }
}

/** Without a repository the popover lists the accounts and never badges the button; without an account it offers the one Add account sheet. */
export async function accountQuickControlsWithoutRepositorySelfTest(): Promise<[boolean, string]> {
  const original = { accounts: accounts.accounts, status: accounts.status };
  const host = document.createElement("div"); document.body.append(host);
  const root = createRoot(host);
  const alice: HostAccount = { id: "bare-alice", provider: "github", server: "https://github.com", username: "alice", name: "Alice", avatarURL: null };
  const carol: HostAccount = { id: "bare-carol", provider: "gitlab", server: "https://gitlab.example.com", username: "carol", name: "Carol", avatarURL: null };
  const trigger = () => host.querySelector<HTMLButtonElement>(".account-quick-trigger");
  const opened: unknown[] = [];
  const onSettings = (event: Event) => { event.stopImmediatePropagation(); opened.push((event as CustomEvent).detail); };
  // the step listens first, so the app's own listener does not open Settings over the next steps
  window.addEventListener("gitrochi-open-settings", onSettings, true);
  try {
    accounts.accounts = [alice, carol]; accounts.status = (account) => (account.id === alice.id ? "expired" : "signedIn");
    const store = new RepoStore();
    root.render(createElement(AccountQuickControls, { store }));
    if (!await until(() => trigger()?.textContent === "A")) return [false, `The button must show the first account's photo: ${host.textContent}`];
    if (trigger()!.querySelector(".account-quick-badge")) return [false, "With no repository open there is no badge"];
    trigger()!.click();
    if (!await until(() => !!inPopover("Manage accounts…"))) return [false, "The popover did not open"];
    const panel = popover()!;
    const listed = Array.from(panel.querySelectorAll(".account-popover-row .account-popover-title")).map((item) => item.textContent);
    if (listed.join("|") !== "@alice· github.com|@carol· gitlab.example.com") return [false, `Listed accounts: ${listed.join("|")}`];
    if (!panel.textContent?.includes(t("Open a repository to see which account it uses.")) || panel.textContent.includes(t("This repository")) || inPopover("Change…")) return [false, "Without a repository there is no repository section, only the accounts"];
    if (!panel.textContent.includes(`${t("Signed in")} · ${t("Self-hosted GitLab")}`) || !panel.querySelector(`[data-account="${alice.id}"] [data-status="expired"]`) || !inPopover("Sign in again…")) return [false, "Each account must show its state"];
    inPopover("Manage accounts…")!.click();
    if (!await until(() => opened.length === 1 && !popover())) return [false, "Manage accounts… did not ask for Settings"];
    if (opened[0] !== "accounts") return [false, `Manage accounts… must open Settings › Accounts: ${String(opened[0])}`];
    trigger()!.click();
    if (!await until(() => !!inPopover("Inbox"))) return [false, "The popover did not reopen"];
    inPopover("Inbox")!.click();
    if (!await until(() => store.destination === "account" && !popover())) return [false, "Inbox did not open the Account page"];
    if (store.path || store.me || store.gitchStatus) return [false, "The popover changed the repository's Git identity"];

    // a GitHub/GitLab remote without an account on its host says so
    const remote = new RepoStore(); remote.path = "/fixture/bare"; remote.target = { provider: "github", host: "github.example.com", path: "team/repo", remote: "origin" };
    root.render(createElement(AccountQuickControls, { store: remote }));
    if (!await until(() => !!trigger() && !trigger()!.querySelector(".avatar"))) return [false, "A remote without an account must show the signed-out button"];
    trigger()!.click();
    if (!await until(() => popover()?.textContent?.includes(t("Connect an account on {0} to use repository services.", "github.example.com")) === true)) return [false, "A remote without an account must say which server needs one"];
    trigger()!.click();

    // no account at all: the blocked state, whose one filled button opens the Add account sheet
    accounts.accounts = [];
    root.render(createElement(AccountQuickControls, { store: new RepoStore() }));
    if (!await until(() => !!trigger() && !trigger()!.querySelector(".avatar") && !popover())) return [false, "Without an account the button must show the signed-out drawing"];
    trigger()!.click();
    if (!await until(() => !!popover()?.querySelector(".account-popover-empty .btn.primary"))) return [false, "Without an account the popover must offer Add account… as its one filled button"];
    if (!popover()!.textContent?.includes(t("No account")) || popover()!.querySelectorAll(".btn.primary").length !== 1) return [false, "The blocked state must be one line, one caption and one filled action"];
    popover()!.querySelector<HTMLButtonElement>(".account-popover-empty .btn.primary")!.click();
    if (!await until(() => !!document.querySelector(".add-account-sheet") && !popover())) return [false, "Add account… did not open the Add account sheet"];
    if (document.querySelector(".add-account-sheet .shared-sheet-title")?.textContent !== t("Add account")) return [false, "The Add account sheet has the wrong title"];
    document.querySelector<HTMLButtonElement>(".add-account-sheet .shared-sheet-cancel")!.click();
    if (!await until(() => !document.querySelector(".add-account-sheet"))) return [false, "The Add account sheet did not close"];
    return [true, "The accounts are listed with their states and no badge; Manage accounts… and Inbox lead to Settings › Accounts and the Account page; without an account the one filled button opens the Add account sheet"];
  } finally {
    window.removeEventListener("gitrochi-open-settings", onSettings, true);
    root.unmount(); await sleep(25); host.remove(); popover()?.remove();
    accounts.accounts = original.accounts; accounts.status = original.status;
  }
}
