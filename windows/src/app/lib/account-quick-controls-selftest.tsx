import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { AccountQuickControls } from "@/widgets/toolbar";
import { type HostAccount } from "@/entities/git";
import { gitch, type GitchBrowserLogin, type GitHubLoginCapability } from "@/entities/gitch";
import { accounts } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (check: () => boolean) => { for (let attempt = 0; attempt < 100; attempt++) { if (check()) return true; await sleep(20); } return false; };

/** 실제 계정·인증을 바꾸지 않고 우측 선택·Git 잠금 표시·명시적 승인 경계를 검사한다. */
export async function accountQuickControlsSelfTest(): Promise<[boolean, string]> {
  const original = { accounts: accounts.accounts, accountFor: accounts.accountFor, start: gitch.startBrowserLogin, status: gitch.browserLoginStatus, cancel: gitch.cancelBrowserLogin };
  const host = document.createElement("div"); host.hidden = true; document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const alice: HostAccount = { id: "quick-alice", provider: "github", server: "https://github.com", username: "alice", name: "Alice", avatarURL: null };
  const bob: HostAccount = { ...alice, id: "quick-bob", username: "bob", name: "Bob" };
  let active = alice, selections = 0, starts = 0;
  let requested: { capability?: GitHubLoginCapability; login?: string } | null = null;
  const flow: GitchBrowserLogin = { schemaVersion: 1, session: "github-quickQA123", state: "pending", phase: "queued", deviceCode: null, verificationURL: "https://github.com/login/device", login: null, email: null, message: "Fake sign-in only" };
  const button = (label: string) => Array.from(document.querySelectorAll<HTMLButtonElement>("button")).find((item) => item.textContent?.trim() === t(label));
  try {
    accounts.accounts = [alice, bob]; accounts.accountFor = () => active;
    store.path = "/fixture/quick-accounts"; store.target = { provider: "github", host: "github.com", path: "owner/repository", remote: "origin" };
    store.me = { name: "Git Author", email: "author@example.invalid" };
    store.gitchStatus = { inRepo: true, lockedAccount: "locked-git-user", account: "locked-git-user", accountSource: "lock", pushAccount: "locked-git-user", ignored: false };
    store.useAccount = (account) => { active = account; selections++; store.changed(); };
    gitch.startBrowserLogin = async (capability, login) => { starts++; requested = { capability, login }; return flow; };
    gitch.browserLoginStatus = async () => flow; gitch.cancelBrowserLogin = async () => ({ ...flow, state: "cancelled" });
    root.render(createElement(AccountQuickControls, { store }));
    if (!await until(() => !!host.querySelector("button"))) return [false, "Quick account control missing"];
    if (!host.textContent?.includes("@alice") || !host.textContent.includes("locked-git-user")) return [false, "Current service and locked Git accounts are not visible"];
    host.querySelector<HTMLButtonElement>("button")!.click();
    if (!await until(() => !!document.querySelector(".account-quick-popover select"))) return [false, "Quick account popover did not open"];
    const panel = document.querySelector(".account-quick-popover")!;
    if (!panel.textContent?.includes("author@example.invalid") || !panel.textContent.includes(t("Locked"))) return [false, "Git author and lock metadata are missing"];
    const select = panel.querySelector<HTMLSelectElement>("select")!; select.value = bob.id; select.dispatchEvent(new Event("change", { bubbles: true }));
    if (!await until(() => host.textContent?.includes("@bob") === true)) return [false, "Repository account selection did not update the right control"];
    if (store.gitchStatus.lockedAccount !== "locked-git-user" || store.me.name !== "Git Author" || starts !== 0) return [false, "Repository service selection changed Git identity or started sign-in"];
    button("Connect GitHub project access")!.click();
    if (!await until(() => !!button("Continue to approve project access"))) return [false, "Project permission reconnect did not open from the right control"];
    if (starts !== 0 || !document.body.textContent?.includes(t("Approve access with the selected account: @{0}", "bob"))) return [false, "Project access did not wait for the selected account's explicit approval"];
    button("Continue to approve project access")!.click();
    if (!await until(() => starts === 1)) return [false, "Explicit project permission click did not start sign-in"];
    const captured = requested as { capability?: GitHubLoginCapability; login?: string } | null;
    return [captured?.capability === "projects" && captured.login === "bob" && selections === 1 && store.gitchStatus.lockedAccount === "locked-git-user", JSON.stringify({ selections, starts, requested })];
  } finally {
    root.unmount(); await sleep(25); host.remove();
    accounts.accounts = original.accounts; accounts.accountFor = original.accountFor;
    gitch.startBrowserLogin = original.start; gitch.browserLoginStatus = original.status; gitch.cancelBrowserLogin = original.cancel;
  }
}
