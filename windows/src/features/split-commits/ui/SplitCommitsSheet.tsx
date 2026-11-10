import { ArrowDown, ArrowUp } from "@/shared/icons";
import { useState } from "react";
import { type SplitGroup, StatusBadge } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, Modal } from "@/shared/ui";

/** 나눠서 커밋: AI 가 나눈 계획을 보고 메시지·파일을 고친 뒤 차례로 커밋 */
export function SplitCommitsSheet({ store, close }: { store: RepoStore; close: () => void }) {
  useObserve(store);
  const [groups, setGroups] = useState<SplitGroup[]>(() => store.splitPlan ?? []);
  const changes = new Map(store.splittableChanges.map((c) => [c.path, c]));
  const valid = groups.filter((g) => g.files.length);
  const ready = valid.length > 0 && valid.every((g) => g.message.trim());
  const leftover = store.splittableChanges.map((c) => c.path).filter((p) => !groups.some((g) => g.files.includes(p)));

  const update = (id: string, f: (g: SplitGroup) => SplitGroup) => setGroups((gs) => gs.map((g) => (g.id === id ? f(g) : g)));
  const move = (path: string, to: string) =>
    setGroups((gs) => {
      let next = gs.map((g) => ({ ...g, files: g.files.filter((p) => p !== path) }));
      if (to === "new") next = [...next, { id: crypto.randomUUID(), message: "", files: [path] }];
      else if (to !== "skip") next = next.map((g) => (g.id === to ? { ...g, files: [...g.files, path] } : g));
      return next;
    });
  const shift = (i: number, d: number) =>
    setGroups((gs) => {
      const j = i + d;
      if (j < 0 || j >= gs.length) return gs;
      const n = [...gs];
      [n[i], n[j]] = [n[j], n[i]];
      return n;
    });

  const fileRow = (p: string, current: string | null) => {
    const c = changes.get(p);
    return (
      <div key={p} className="file-row" style={{ paddingLeft: 2 }}>
        {c && <StatusBadge kind={c.kind} />}
        <span className="ellipsis grow" data-tip={p}>
          {p}
        </span>
        <select className="select" style={{ width: 150, height: 24, padding: "0 4px", fontSize: 12 }} value={current ?? "skip"} onChange={(e) => move(p, e.target.value)}>
          {groups.map((g, i) => (
            <option key={g.id} value={g.id}>
              {t("To commit {0}", i + 1)}</option>
          ))}
          <option value="new">{t("To a new commit")}</option>
          <option value="skip">{t("Not committed")}</option>
        </select>
      </div>
    );
  };

  return (
    <Modal
      title={t("Split into commits")}
      width={720}
      onClose={close}
      footer={
        <>
          <span className="hint grow">
            {t("Clears the staging area, then stages and commits each group from the top. {0}", leftover.length > 0 ? t("{0} files that aren't committed stay as they are.", leftover.length) : "")}</span>
          <Button
            disabled={!!store.aiWorking}
            onClick={() => {
              close();
              void store.planSplit();
            }}
          >
            {t("Split again")}</Button>
          <Button onClick={close}>{t("Cancel")}</Button>
          <Button
            kind="primary"
            disabled={!ready || store.busy != null}
            onClick={() => {
              const plan = valid;
              close();
              void store.applySplit(plan);
            }}
          >
            {t("Create {0} commits", valid.length)}</Button>
        </>
      }
    >
      {store.aiNotice && <span className="hint">{store.aiNotice}</span>}
      {groups.map((g, i) =>
        g.files.length === 0 ? null : (
          <div key={g.id} className="form-section" style={{ gap: 6 }}>
            <div className="row">
              <span className="form-section-title">{t("Commit {0}", i + 1)}</span>
              <span className="muted">{t("{0} files", g.files.length)}</span>
              <span className="spacer" />
              <IconButton small icon={<ArrowUp size={13} />} tip={t("Up")} disabled={i === 0} onClick={() => shift(i, -1)} />
              <IconButton small icon={<ArrowDown size={13} />} tip={t("Down")} disabled={i === groups.length - 1} onClick={() => shift(i, 1)} />
            </div>
            <textarea
              className="textarea"
              style={{ height: 58, fontSize: 12.5 }}
              value={g.message}
              placeholder={t("Commit message (the first line is the summary)")}
              onChange={(e) => update(g.id, (x) => ({ ...x, message: e.target.value }))}
              spellCheck={false}
            />
            {g.files.map((p) => fileRow(p, g.id))}
          </div>
        ),
      )}
      {leftover.length > 0 && (
        <div className="form-section" style={{ gap: 6, opacity: 0.85 }}>
          <span className="form-section-title">{t("Not committed")}</span>
          {leftover.map((p) => fileRow(p, null))}
        </div>
      )}
    </Modal>
  );
}
