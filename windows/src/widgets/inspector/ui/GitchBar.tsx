import { CircleCheck, CircleX, Ellipsis, Lock, TriangleAlert, User } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { GitchLevel, GitchStatus } from "@/entities/gitch";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, IconButton, type MenuItem, showMenuBelow, Spinner } from "@/shared/ui";

/**
 * 커밋 칸 위: gitch 가 보는 이 저장소의 계정과 커밋·push 전 점검(gitch 계정을 만들어 두었을 때만). (맥 버전 GitchBar)
 * 계정 이름을 눌러 이 저장소에 쓸 계정을 바꾸고(gitch use · unlock), ⋯ 메뉴로 저장소 단위 gitch 명령을 쓴다.
 */
export function GitchBar({ store }: { store: RepoStore }) {
  const s = store.gitchStatus;
  const [showChecks, setShowChecks] = useState(false);
  if (!s) return null;
  const p = store.gitchPreflight;
  const accountMenu = (el: HTMLElement) => {
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
      items.push("divider", {
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
    showMenuBelow(el, items);
  };
  return (
    <div className="gitch-bar">
      <span className="gitch-name">gitch</span>
      <span className={s.account ? "muted" : "gitch-warn"} style={{ display: "inline-flex" }}>
        {!s.account ? <TriangleAlert size={12} /> : s.lockedAccount ? <Lock size={12} /> : <User size={12} />}
      </span>
      <button
        className="link gitch-account"
        disabled={!store.gitchAccounts.length || store.busy != null}
        data-tip={summary(s) + "|" + t("Click to use another gitch account for this repository.")}
        onClick={(e) => accountMenu(e.currentTarget)}
      >
        {s.account ?? t("No account")}
      </button>
      {s.ignored && <span className="muted ellipsis">{t("Not managed by gitch")}</span>}
      <span className="spacer" />
      {store.gitchChecking && <Spinner size={11} />}
      {p && (
        <span>
          <button className={`gitch-pill ${levelClass(p.result)}`} data-tip={t("gitch checks before commit and push")} onClick={() => setShowChecks((v) => !v)}>
            <LevelIcon level={p.result} /> {levelTitle(p.result)}
          </button>
          {showChecks && <GitchChecks store={store} onClose={() => setShowChecks(false)} />}
        </span>
      )}
      <IconButton
        small
        icon={<Ellipsis size={14} />}
        tip={t("gitch commands for this repository")}
        disabled={store.busy != null}
        onClick={(e) => showMenuBelow(e.currentTarget, actions(store, s))}
      />
    </div>
  );
}

/** ⋯ 메뉴: 저장소 단위 gitch 명령(터미널의 gitch up · sync · fix · rescue · ignore · doctor 와 같다) */
function actions(store: RepoStore, s: GitchStatus): MenuItem[] {
  const items: MenuItem[] = [{ label: t("Follow the default branch"), onClick: () => void store.gitchUp() }];
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
    { label: t("Run doctor in the terminal"), onClick: () => void store.runGitchInTerminal(["doctor"]) },
  );
  return items;
}

function summary(s: GitchStatus) {
  if (!s.account) return t("gitch doesn't know which account this repository uses. Lock it with gitch use <account>.");
  let text = s.accountSource === "lock" ? t("Locked to {0}", s.account) : t("{0} (chosen by a gitch rule)", s.account);
  if (s.pushAccount && s.pushAccount !== s.account) text += " · " + t("Pushes as {0}", s.pushAccount);
  return text;
}

const levelClass = (l: GitchLevel) => (l === "OK" ? "ok" : l === "WARN" ? "warn" : "stop");

function levelTitle(l: GitchLevel) {
  return l === "OK" ? t("Ready") : l === "WARN" ? t("Warning") : t("Blocked");
}

function LevelIcon({ level }: { level: GitchLevel }) {
  return level === "OK" ? <CircleCheck size={12} /> : level === "WARN" ? <TriangleAlert size={12} /> : <CircleX size={12} />;
}

/** 점검 항목(문구는 gitch 가 낸 그대로)과 다시 점검하기 */
function GitchChecks({ store, onClose }: { store: RepoStore; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const down = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node) && !(e.target as HTMLElement).closest?.(".gitch-pill")) onClose();
    };
    const key = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("mousedown", down);
    window.addEventListener("keydown", key);
    return () => {
      window.removeEventListener("mousedown", down);
      window.removeEventListener("keydown", key);
    };
  }, [onClose]);
  const p = store.gitchPreflight;
  return (
    <div className="gitch-popover" ref={ref}>
      <div style={{ fontWeight: 600 }}>{t("gitch checks before commit and push")}</div>
      {p?.checks.map((c, i) => (
        <div key={i} className="row" style={{ alignItems: "flex-start", gap: 6 }}>
          <span className={levelClass(c.level)} style={{ display: "inline-flex", paddingTop: 2 }}>
            <LevelIcon level={c.level} />
          </span>
          <span className="selectable" style={{ whiteSpace: "pre-wrap" }}>
            {c.message}
          </span>
        </div>
      ))}
      <div className="gitch-popover-footer row">
        <Button size="small" disabled={store.gitchChecking} onClick={() => void store.refreshGitch(true)}>
          {t("Check again with fetch")}
        </Button>
        {store.gitchChecking && <Spinner size={12} />}
        <span className="spacer" />
        <Button
          size="small"
          onClick={() => {
            onClose();
            void store.runGitchInTerminal(["doctor"]);
          }}
        >
          {t("Run doctor in the terminal")}
        </Button>
      </div>
    </div>
  );
}
