import { accountHost, type HostAccount, type RepoTarget } from "@/entities/git";
import { t } from "@/shared/i18n";

// What the account button, its popover and Settings › Accounts say about an account (docs/design.md, App shell).
// macOS: Core/AccountPresentation.swift — the same rules, keep both in step.

/**
 * What a hosting account needs from the user. `needsApproval`: the organization asks to approve access again in the
 * browser. `needsYourApproval`: the system must allow the saved sign-in. `expired`: the server rejected the saved
 * token. `unreadable`: the saved sign-in can't be read, and reading it again may be all it takes. `checking`: the
 * first read is under way and nothing is known yet.
 */
export type AccountStatus = "signedIn" | "needsApproval" | "needsYourApproval" | "expired" | "unreadable" | "checking";

/** Which drawing a state uses: the states that need the user never share one with the lock */
export type AccountStatusIcon = "check" | "shield" | "key" | "warning" | "clock";

export const accountStatusIcon = (status: AccountStatus): AccountStatusIcon =>
  status === "needsApproval" ? "shield" : status === "needsYourApproval" || status === "unreadable" ? "key" : status === "expired" ? "warning" : status === "checking" ? "clock" : "check";

export const accountStatusTitle = (status: AccountStatus) =>
  status === "needsApproval" ? t("Needs approval") : status === "needsYourApproval" ? t("Needs your approval") : status === "expired" ? t("Sign-in expired")
    : status === "unreadable" ? t("Saved sign-in can't be read") : status === "checking" ? t("Checking saved account access…") : t("Signed in");

/** The one action that settles a state, or null when there is nothing to do */
export const accountStatusAction = (status: AccountStatus) =>
  status === "needsApproval" ? t("Renew…") : status === "needsYourApproval" ? t("Approve…") : status === "expired" ? t("Sign in again…") : status === "unreadable" ? t("Retry") : null;

/** What the state means, for the notice above this repository's account; null where the title says it all */
export const accountStatusCaption = (status: AccountStatus) =>
  status === "needsApproval" ? t("The organization asks to approve access again in the browser.") : status === "expired" ? t("The token expired or was revoked.")
    : status === "unreadable" ? t("Saved credentials are unavailable. Retry access or reconnect this account in Settings.") : null;

/** Where a read of the saved sign-in stands (macOS: CredentialCache.State) */
export type CredentialState = "ready" | "loading" | "authorizationRequired" | "unavailable";

/**
 * What a saved credential's read says about the account. An unreadable credential is not an expired sign-in: only a
 * token the server rejected is. While a read or an approval is under way the account keeps the state it had, so a row
 * never claims "Signed in" and the badge never clears before the answer is known.
 */
export const accountStatusFor = (credential: CredentialState, rejected: boolean, previous: AccountStatus | null): AccountStatus =>
  credential === "ready" ? "signedIn" : credential === "loading" ? previous ?? "checking" : credential === "authorizationRequired" ? "needsYourApproval" : rejected ? "expired" : "unreadable";

/**
 * The toolbar's warning badge: only when the open repository's own account needs attention. Another account that
 * needs something is flagged inside the popover, and a window without a repository account has no badge.
 */
export const toolbarAccountBadge = (repositoryAccountStatus: AccountStatus | null) =>
  repositoryAccountStatus !== null && repositoryAccountStatus !== "signedIn" && repositoryAccountStatus !== "checking";

/** Why a repository uses its account */
export type AccountReason =
  | { kind: "chosen" }
  | { kind: "matches"; repository: string }
  | { kind: "first"; host: string }
  | { kind: "sameServer"; host: string };

/**
 * The user's own choice comes first; then an account reached through another address of the same server; then the
 * first of several accounts on the host; otherwise the only account that matches the repository's host.
 */
export function accountReason(account: HostAccount, target: RepoTarget, candidates: HostAccount[], preferredID: string | null): AccountReason {
  if (preferredID === account.id) return { kind: "chosen" };
  if (accountHost(account) !== target.host) return { kind: "sameServer", host: target.host };
  if (candidates.length > 1) return { kind: "first", host: target.host };
  return { kind: "matches", repository: target.path };
}

export const accountReasonText = (reason: AccountReason) =>
  reason.kind === "chosen" ? t("Chosen for this repository")
    : reason.kind === "sameServer" ? t("Same server as {0}", reason.host)
      : reason.kind === "first" ? t("First account on {0}", reason.host)
        : t("Matches {0}", reason.repository);

/** The letter an account without a photo shows: from its name, else its username */
export function accountInitial(name: string | null | undefined, username: string): string {
  const [first] = Array.from((name ?? "").trim() || username.trim());
  return first ? first.toLocaleUpperCase() : "?";
}
