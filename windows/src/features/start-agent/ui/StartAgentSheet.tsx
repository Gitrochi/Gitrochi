import { useEffect, useState } from "react";
import { agentKind, type AgentKind, agentKinds, agents, skipsPermissions } from "@/entities/agent";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { displayPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve, validBranchName } from "@/shared/lib";
import { tools } from "@/shared/platform";
import { Checkbox, Frame, Row, Segmented } from "@/shared/ui";

export function StartAgentSheet({ store, close, presetPath }: { store: RepoStore; close: () => void; presetPath: string | null }) {
  useObserve(tools);
  /** 빈 문자열 = 새 워크트리 만들기 */
  const [target, setTarget] = useState(presetPath ?? store.path ?? store.worktrees[0]?.path ?? "");
  const [kind, setKind] = useState<AgentKind>(agents.defaultKind);
  const [newBranch, setNewBranch] = useState("");
  const [task, setTask] = useState("");
  const [mode, setMode] = useState("");
  const [riskAccepted, setRiskAccepted] = useState(false);
  const [exists, setExists] = useState(false);
  const info = agentKind(kind);
  const found = tools.available(info.tool);
  const wtPath = newBranch.trim() ? store.defaultWorktreePath(newBranch.trim()) : "";
  useEffect(() => {
    if (wtPath) void ipc.exists(wtPath).then(setExists);
  }, [wtPath]);
  useEffect(() => setMode(""), [kind]);
  const validBranch = validBranchName(newBranch) && !exists;
  const bypass = skipsPermissions(kind, mode);
  return (
    <Frame
      title={t("Start agent session")}
      confirm={t("Start")}
      width={580}
      canConfirm={found && (!!target || validBranch) && (!bypass || riskAccepted)}
      close={close}
      leftFooter={t("Runs in a new tab of the terminal below; its status is shown in the Agents tab.")}
      onConfirm={() =>
        void (async () => {
          const m = mode || null;
          if (!target) {
            if (await store.addWorktree(wtPath, newBranch.trim(), true, null, false, "")) await store.startAgent(wtPath, task, m, kind);
          } else await store.startAgent(target, task, m, kind);
        })()
      }
    >
      <Row label={t("Agents")}>
        <Segmented
          value={kind}
          onChange={setKind}
          options={agentKinds.map((k) => ({
            value: k.id,
            label: (
              <span style={{ opacity: tools.available(k.tool) ? 1 : 0.45 }}>
                {k.title.split(" (")[0]}
                {tools.wsl(k.tool) ? " · WSL" : ""}
              </span>
            ),
            tip: tools.available(k.tool) ? `${k.title}|${tools.describe(k.tool)}` : t("{0} — not found (locate it or find it in WSL in Settings > Tools)", k.title),
          }))}
        />
      </Row>
      {!found && <span className="error-text">{t("Couldn't find the {0} executable. Locate it in Settings > Tools, or if you installed it in WSL, click 'Find in WSL'.", info.title)}</span>}
      {found && tools.wsl(info.tool) && <span className="hint">{t("Runs inside WSL ({0}). The working folder is opened as a Linux path.", tools.wsl(info.tool)!.distro)}</span>}
      <Row label={t("Where to work")}>
        <select className="select" value={target} onChange={(e) => setTarget(e.target.value)}>
          {store.worktrees.map((w) => (
            <option key={w.path} value={w.path}>
              {(w.branch ?? t("Detached HEAD")) + (w.path === store.path ? t("  (opened here)") : "")}
            </option>
          ))}
          <option value="">{t("Create new worktree…")}</option>
        </select>
      </Row>
      {!target && (
        <>
          <Row label={t("New branch name")}>
            <input className="input" autoFocus value={newBranch} placeholder={t("feature/ai-work")} onChange={(e) => setNewBranch(e.target.value)} spellCheck={false} />
          </Row>
          <Row label={t("Location")}>
            <span className="ellipsis muted">{wtPath ? displayPath(wtPath) : "-"}</span>
          </Row>
        </>
      )}
      <Row label={t("Task")}>
        <textarea className="textarea" style={{ height: 80 }} value={task} placeholder={t("e.g. add a lockout after failed logins, including tests")} onChange={(e) => setTask(e.target.value)} />
      </Row>
      <Row label={t("Permission mode")}>
        <select
          className="select"
          value={mode}
          onChange={(e) => {
            setMode(e.target.value);
            setRiskAccepted(false);
          }}
        >
          {info.modes.map((m) => (
            <option key={m.value} value={m.value}>
              {m.label}
            </option>
          ))}
        </select>
      </Row>
      {bypass && (
        <>
          <span className="error-text">{t("The agent runs commands and changes files without asking first. Use it only for tasks you trust, ideally in a separate worktree.")}</span>
          <Checkbox checked={riskAccepted} onChange={setRiskAccepted} label={t("I understand the risk")} />
        </>
      )}
    </Frame>
  );
}
