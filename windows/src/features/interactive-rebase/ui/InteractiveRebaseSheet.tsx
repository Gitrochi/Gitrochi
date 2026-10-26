import { ArrowDown, ArrowUp, TriangleAlert } from "lucide-react";
import { useState } from "react";
import { planChanged, planProblem, rebaseActions, type RebaseItem, type RebasePlan } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, Modal } from "@/shared/ui";
import "./interactive-rebase.css";

/** 커밋 정리(인터랙티브 리베이스): 커밋마다 그대로·메시지 고치기·아래 커밋에 합치기·빼기를 고르고 순서를 바꾼다 (맥 버전 InteractiveRebaseSheet) */
export function InteractiveRebaseSheet({ store, close, embedded = false }: { store: RepoStore; close: () => void; embedded?: boolean }) {
  useObserve(store);
  const [plan, setPlan] = useState<RebasePlan | null>(() => store.rebasePlan);
  if (!plan) return null;
  const problem = planProblem(plan);
  const update = (i: number, f: (it: RebaseItem) => RebaseItem) => setPlan({ ...plan, items: plan.items.map((it, n) => (n === i ? f(it) : it)) });
  const shift = (i: number, d: number) => {
    const j = i + d;
    if (j < 0 || j >= plan.items.length) return;
    const items = [...plan.items];
    [items[i], items[j]] = [items[j], items[i]];
    setPlan({ ...plan, items });
  };

  const footer = (
        <>
          <span className="hint grow" style={problem ? { color: "var(--red)" } : undefined}>
            {problem ?? t("You can always return to the state before you started (Undo, Ctrl+Z).")}
          </span>
          <Button onClick={close}>{t("Cancel")}</Button>
          <Button
            kind="primary"
            disabled={!!problem || !planChanged(plan) || store.busy != null}
            onClick={() => {
              close();
              void store.runInteractiveRebase(plan);
            }}
          >
            {t("Start cleanup")}</Button>
        </>
  );
  const content = <>
      <div className="col" style={{ gap: 4, marginBottom: 10 }}>
        <span className="muted">
          {t("{1} commits on '{0}' — newest at the top. Squash combines a commit into the one right below it (older).", store.headBranch, plan.items.length)}</span>
        {plan.pushed && (
          <span style={{ color: "var(--orange)", fontSize: 12 }}>
            <TriangleAlert size={12} style={{ verticalAlign: -2 }} /> {" "}{t("Includes commits already pushed to the remote. You'll need to force push after cleaning up.")}</span>
        )}
      </div>
      <div className="col rebase-list">
        {plan.items.map((it, i) => (
          <div key={it.sha} className={`rebase-item ${it.action}`}>
            <div className="row" style={{ gap: 8 }}>
              <select
                className="select"
                style={{ width: 210, height: 26, padding: "0 6px" }}
                value={it.action}
                aria-label={t("What to do with this commit")}
                onChange={(e) => update(i, (x) => ({ ...x, action: e.target.value as RebaseItem["action"] }))}
              >
                {rebaseActions.map((a) => (
                  <option key={a.value} value={a.value}>
                    {a.title}
                  </option>
                ))}
              </select>
              <span className="mono muted">{it.sha.slice(0, 7)}</span>
              <span className="ellipsis grow rebase-subject" data-tip={it.message}>
                {it.subject}
              </span>
              <span className="muted ellipsis" style={{ fontSize: 11.5, maxWidth: 120 }}>
                {it.author}
              </span>
              <IconButton icon={<ArrowUp size={14} />} aria-label={t("Up")} tip={t("Up (later)")} disabled={i === 0} onClick={() => shift(i, -1)} />
              <IconButton icon={<ArrowDown size={14} />} aria-label={t("Down")} tip={t("Down (earlier)")} disabled={i === plan.items.length - 1} onClick={() => shift(i, 1)} />
            </div>
            {it.action === "reword" && (
              <textarea className="input" style={{ height: 64, marginTop: 6 }} value={it.newMessage} onChange={(e) => update(i, (x) => ({ ...x, newMessage: e.target.value }))} />
            )}
          </div>
        ))}
      </div>
  </>;
  return embedded ? <div className="col" style={{ flex: 1, minHeight: 0 }}>{content}<div className="row" style={{ marginTop: 14 }}>{footer}</div></div> : <Modal title={t("Clean up commits")} width={720} onClose={close} footer={footer}>{content}</Modal>;
}
