import type { GitchStatus } from "@/entities/gitch";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import type { MenuItem } from "@/shared/ui";

/**
 * ⋯ › gitch: the account gitch uses for this repository and its repository commands (gitch use · unlock · up · sync ·
 * fix · rescue · ignore · doctor). They sat in a bar over the commit form, which the redesign leaves out.
 * macOS: GitchMenu in Views/RepoView.swift
 */
export function gitchMenu(store: RepoStore, s: GitchStatus): MenuItem[] {
  const items: MenuItem[] = store.gitchAccounts.map((a) => ({
    label: `${a.id} · ${a.email}`,
    checked: a.id === s.lockedAccount,
    disabled: a.id === s.lockedAccount,
    onClick: () =>
      store.ask({
        title: t("Use {0} for this repository?", a.id),
        message: t("gitch sets the commit author to {0} and points origin (and upstream) at {1}'s SSH alias, then locks the repository to it.", a.email, a.id),
        actionTitle: t("Use this account"),
        action: () => store.useGitchAccount(a.id),
      }),
  }));
  if (s.lockedAccount) {
    items.push({
      label: t("Unlock this repository…"),
      onClick: () =>
        store.ask({
          title: t("Unlock this repository?"),
          message: t("gitch stops requiring {0} for commits and pushes here. The commit author stays as it is.", s.lockedAccount),
          actionTitle: t("Unlock"),
          action: () => store.unlockGitch(),
        }),
    });
  }
  if (items.length) items.push("divider");
  items.push({ label: t("Follow the default branch"), onClick: () => void store.gitchUp() });
  if (store.remotes.includes("upstream")) items.push({ label: t("Update the fork from upstream"), onClick: () => void store.gitchSync() });
  items.push(
    "divider",
    { label: t("Fix authors of unpushed commits…"), onClick: () => void store.confirmGitchFix() },
    { label: t("Backups…"), onClick: () => store.openSheet({ kind: "gitchBackups" }) },
    "divider",
    s.ignored
      ? { label: t("Check this repository with gitch again"), onClick: () => void store.setGitchIgnored(false) }
      : {
          label: t("Exclude this repository from gitch checks…"),
          onClick: () =>
            store.ask({
              title: t("Exclude this repository from gitch checks?"),
              message: t("gitch won't check authors, secrets or pushes in this repository until you turn it back on."),
              actionTitle: t("Exclude"),
              destructive: true,
              action: () => store.setGitchIgnored(true),
            }),
        },
    { label: t("Check again with fetch"), disabled: store.gitchChecking, onClick: () => void store.refreshGitch(true) },
    { label: t("Run doctor in the terminal"), onClick: () => void store.runGitchInTerminal(["doctor"]) },
  );
  return items;
}
