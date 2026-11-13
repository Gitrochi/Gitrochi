import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { type HostAccount } from "@/entities/git";
import { gitch } from "@/entities/gitch";
import { accounts } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { AccountsSettings } from "@/widgets/settings";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (check: () => boolean) => { for (let attempt = 0; attempt < 125; attempt++) { if (check()) return true; await sleep(20); } return false; };
const menuItems = () => [...document.querySelectorAll<HTMLElement>(".menu .menu-item .label")].map((item) => item.textContent ?? "");
const menuItem = (label: string) => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.querySelector(".label")?.textContent === t(label));

/** Settings › Accounts lists hosting accounts and Git identities, opens the one Add account sheet, and is where an account is removed, after asking. */
export async function accountsSettingsSelfTest(): Promise<[boolean, string]> {
  const original = { accounts: accounts.accounts, status: accounts.status, disconnect: accounts.disconnect, identities: gitch.accounts };
  const host = document.createElement("div"); host.style.width = "600px"; document.body.append(host);
  const root = createRoot(host);
  const alice: HostAccount = { id: "settings-alice", provider: "github", server: "https://github.com", username: "alice", name: "Alice", avatarURL: null };
  const carol: HostAccount = { id: "settings-carol", provider: "gitlab", server: "https://gitlab.example.com", username: "carol", name: "Carol", avatarURL: null };
  const removed: string[] = [];
  const $ = <T extends Element = HTMLElement>(selector: string) => document.querySelector<T>(selector);
  try {
    accounts.accounts = [alice, carol]; accounts.status = () => "signedIn";
    accounts.disconnect = async (account) => { removed.push(account.id); };
    gitch.accounts = async () => [{ id: "alice", hosts: "github.com, ssh.github.com(port 443)", email: "alice@example.invalid", rules: "", sshKey: true }];
    root.render(createElement(AccountsSettings));
    if (!await until(() => host.querySelectorAll("[data-identity]").length === 1)) return [false, "The Git identities did not load"];
    const text = host.textContent ?? "";
    if (!text.includes(t("Hosting accounts")) || !text.includes(t("Git identities")) || host.querySelectorAll("[data-account]").length !== 2) return [false, "Hosting accounts and Git identities must each be listed"];
    if (!text.includes("alice@example.invalid") || !text.includes(t("An account used under several host labels (HTTPS, SSH on port 443) is listed once.")) || text.includes(t("Disconnect"))) return [false, "An identity is one row with its host labels, and no row carries a remove button"];
    if (host.querySelectorAll('[data-status="signedIn"]').length !== 2) return [false, "Each hosting account must show its state"];
    for (const row of host.querySelectorAll<HTMLElement>(".accounts-settings-row")) if (row.scrollWidth > row.clientWidth) return [false, "A settings row is clipped"];

    // Add account… opens the same sheet as the popover; GitLab's Connect says what it waits for
    host.querySelector<HTMLButtonElement>(".accounts-settings-add")!.click();
    if (!await until(() => $(".add-account-sheet .shared-sheet-title")?.textContent === t("Add account"))) return [false, "Add account… did not open the Add account sheet"];
    if ($(".add-account-sheet .shared-sheet-primary")?.textContent !== t("Sign in with the browser…")) return [false, "GitHub's primary action must be the browser sign-in"];
    [...document.querySelectorAll<HTMLButtonElement>(".add-account-sheet .segmented button")].find((item) => item.textContent === t("GitLab (self-hosted)"))!.click();
    if (!await until(() => $(".add-account-sheet .disabled-reason-text")?.textContent === t("Enter the server URL and a token first"))) return [false, "GitLab's Connect must be disabled with its reason"];
    if (!$<HTMLButtonElement>(".add-account-sheet .shared-sheet-primary")?.disabled) return [false, "Connect must wait for the server URL and the token"];
    $<HTMLButtonElement>(".add-account-sheet .shared-sheet-cancel")!.click();
    if (!await until(() => !$(".add-account-sheet"))) return [false, "The Add account sheet did not close"];

    // ⋯ ends with Remove account…, which asks before it removes
    host.querySelector<HTMLButtonElement>(`[data-account="${alice.id}"] .accounts-settings-more`)!.click();
    if (!await until(() => !!menuItem("Remove account…"))) return [false, "The account's ⋯ menu did not open"];
    const items = menuItems();
    if (items[items.length - 1] !== t("Remove account…") || !items.includes(t("Renew browser connection…")) || !items.includes(t("Connect project access…")) || !items.includes(t("Copy username"))) return [false, `The ⋯ menu must end with Remove account…: ${items.join(" | ")}`];
    menuItem("Remove account…")!.click();
    if (!await until(() => !!$(".remove-account-sheet .shared-sheet-primary"))) return [false, "Remove account… did not ask first"];
    if (removed.length || $(".remove-account-sheet .shared-sheet-title")?.textContent !== t("Remove @{0}?", "alice")) return [false, "Removing must wait for the confirmation, which names the account"];
    $<HTMLButtonElement>(".remove-account-sheet .shared-sheet-cancel")!.click();
    if (!await until(() => !$(".remove-account-sheet")) || removed.length) return [false, "Cancel must leave the account"];
    host.querySelector<HTMLButtonElement>(`[data-account="${carol.id}"] .accounts-settings-more`)!.click();
    if (!await until(() => !!menuItem("Remove account…"))) return [false, "The GitLab account's ⋯ menu did not open"];
    if (menuItems().includes(t("Renew browser connection…"))) return [false, "Browser renewal is for github.com accounts only"];
    menuItem("Remove account…")!.click();
    if (!await until(() => !!$(".remove-account-sheet .shared-sheet-primary"))) return [false, "Remove account… did not ask for the GitLab account"];
    $<HTMLButtonElement>(".remove-account-sheet .shared-sheet-primary")!.click();
    if (!await until(() => removed.join() === carol.id && !$(".remove-account-sheet"))) return [false, `Confirming must remove that account only: ${removed.join()}`];
    return [true, "Hosting accounts and Git identities are listed once with their state; Add account… opens the shared sheet; Remove account… is the last ⋯ item and asks first"];
  } finally {
    root.unmount(); await sleep(25); host.remove();
    document.querySelector(".add-account-sheet")?.closest(".modal-backdrop")?.remove(); document.querySelector(".remove-account-sheet")?.closest(".modal-backdrop")?.remove();
    accounts.accounts = original.accounts; accounts.status = original.status; accounts.disconnect = original.disconnect; gitch.accounts = original.identities;
  }
}
