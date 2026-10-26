import { Check, ChevronDown, TriangleAlert } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { choiceLines, choiceTitle, conflictProjection, parseConflict, type ConflictBlock, type ConflictDocument, type FileChange } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, showMenuBelow, Spinner } from "@/shared/ui";
import "./resolve-conflict.css";

/** 충돌 해결: 충돌 블록마다 내 것 · 상대 것 · 둘 다 · 직접 고치기를 고르고, 다 고르면 저장하고 해결됨으로 표시 (맥 버전 ConflictView) */
export function ConflictView({ store, change }: { store: RepoStore; change: FileChange }) {
  useEffect(() => {
    void store.loadConflict(change.path);
  }, [store, change.path]);
  const doc = store.conflictPath === change.path ? store.conflictDoc : null;
  if (!doc)
    return (
      <div className="empty">
        <Spinner size={20} />
      </div>
    );
  return doc.blocks.length ? <Resolver store={store} change={change} doc={doc} /> : <NoMarkers store={store} change={change} />;
}

/** 충돌 표시가 없는 충돌(한쪽이 지웠거나 바이너리) */
function NoMarkers({ store, change }: { store: RepoStore; change: FileChange }) {
  const sides = store.conflictSides;
  return (
    <div className="empty">
      <TriangleAlert size={30} />
      <div className="big">{t("Conflict without conflict markers")}</div>
      <div>{t("One side deleted the file, or it's a binary file. Choose whether to keep or delete it.")}</div>
      <div className="row" style={{ gap: 8, marginTop: 4 }}>
        <Button onClick={() => void store.resolveDeleted(change, false)}>{t("Delete this file")}</Button>
        <Button kind="primary" onClick={() => void store.resolveDeleted(change, true)}>
          {t("Keep this file")}</Button>
      </div>
      <div className="row" style={{ gap: 8 }}>
        <Button size="small" onClick={() => void store.resolveWholeFile(change, true)}>
          {t("Use mine ({0})", sides.ours)}</Button>
        <Button size="small" onClick={() => void store.resolveWholeFile(change, false)}>
          {t("Use theirs ({0})", sides.theirs)}</Button>
      </div>
    </div>
  );
}

function Resolver({ store, change, doc }: { store: RepoStore; change: FileChange; doc: ConflictDocument }) {
  const [threeWay, setThreeWay] = useState(true);
  const [base, setBase] = useState(false);
  const [manual, setManual] = useState<string | null>(null);
  const panes = useRef<(HTMLTextAreaElement | null)[]>([]);
  useEffect(() => { setManual(null); }, [doc]);
  const sides = store.conflictSides;
  const done = doc.blocks.filter((b) => store.conflictChoices.has(b.id)).length;
  const result = manual ?? conflictProjection(doc, "result", store.conflictChoices);
  const remaining = parseConflict(result).blocks.length;
  const all = manual !== null ? !remaining && !/^<{7,}(?:[ \t]|$)/m.test(result) : done === doc.blocks.length;
  const syncScroll = (source: HTMLTextAreaElement) => { const ratio = source.scrollTop / Math.max(1, source.scrollHeight - source.clientHeight); for (const target of panes.current) if (target && target !== source) target.scrollTop = ratio * Math.max(0, target.scrollHeight - target.clientHeight); };
  return (
    <div className="col grow" style={{ minHeight: 0 }}>
      <div className="conflict-bar">
        <TriangleAlert size={15} style={{ color: "var(--orange)" }} />
        <span style={{ fontWeight: 600 }}>
          {t("{0} conflicts — {1} chosen", doc.blocks.length, done)}</span>
        <span className="spacer" />
        <Button size="small" onClick={() => setThreeWay(!threeWay)}>{threeWay ? t("Block view") : t("Three-way editor")}</Button>
        <Button size="small" onClick={() => void store.loadConflict(change.path)}>{t("Reload")}</Button>
        <Button
          size="small"
          tip={t("Resolves the whole file to one side at once instead of choosing block by block")}
          onClick={(e) =>
            showMenuBelow(e.currentTarget, [
              { label: t("All mine ({0})", sides.ours), onClick: () => void store.resolveWholeFile(change, true) },
              { label: t("All theirs ({0})", sides.theirs), onClick: () => void store.resolveWholeFile(change, false) },
            ])
          }
        >
          {t("Whole file")}{" "}<ChevronDown size={12} />
        </Button>
        <Button
          size="small"
          kind="primary"
          disabled={!all || !!store.busy}
          tip={all ? t("Saves the file as chosen and stages it") : t("Choose every conflict block before saving")}
          onClick={() => void store.saveConflictResolution(change, manual ?? undefined)}
        >
          {t("Save and mark as resolved")}</Button>
      </div>
      {threeWay && <>
        <div className="conflict-bar"><span>{t("Non-conflicting lines are included automatically.")}</span><span className="spacer" /><Button size="small" onClick={() => setBase(!base)}>{base ? t("Hide common ancestor") : t("Show common ancestor")}</Button>{manual !== null && <Button size="small" onClick={() => setManual(null)}>{t("Use block choices")}</Button>}</div>
        <div className={`conflict-three ${base ? "with-base" : ""}`}>
          {([...(base ? ["base"] : []), "ours", "result", "theirs"] as ("base" | "ours" | "result" | "theirs")[]).map((side, index) => <label key={side} className={`conflict-pane ${side}`}><b>{side === "base" ? t("Common ancestor") : side === "ours" ? t("Mine · {0}", sides.ours) : side === "theirs" ? t("Theirs · {0}", sides.theirs) : t("Final result")}</b><textarea aria-label={side === "result" ? t("Final result") : side} spellCheck={false} wrap="off" readOnly={side !== "result"} ref={(el) => { panes.current[index] = el; }} value={side === "result" ? result : conflictProjection(doc, side)} onChange={(e) => setManual(e.target.value)} onScroll={(e) => syncScroll(e.currentTarget)} /></label>)}
        </div>
        <div className="conflict-bar"><span>{t("{0} unresolved blocks in the result", remaining)}</span>{manual !== null && <span className="hint">{t("Manual result editing is active. Use block choices to rebuild from the selections below.")}</span>}</div>
      </>}
      <div className={`conflict-scroll ${threeWay ? "conflict-block-list" : ""}`}>
        {doc.segments.map((s, i) =>
          s.kind === "text" ? <TextSegment key={i} lines={s.lines} /> : <BlockCard key={i} store={store} block={doc.blocks[s.block]} sides={sides} />,
        )}
      </div>
    </div>
  );
}

/** 충돌 없는 부분: 길면 앞뒤 3줄만 */
function TextSegment({ lines }: { lines: string[] }) {
  const [expanded, setExpanded] = useState(false);
  const short = lines.length > 8 && !expanded;
  return (
    <div className="conflict-text">
      {(short ? lines.slice(0, 3) : lines).map((l, i) => (
        <div key={i}>{l || " "}</div>
      ))}
      {short && (
        <>
          <button type="button" className="link" style={{ fontFamily: "var(--font)", fontSize: 11.5, padding: "2px 0" }} onClick={() => setExpanded(true)}>
            {t("… show {0} more lines", lines.length - 6)}</button>
          {lines.slice(-3).map((l, i) => (
            <div key={`t${i}`}>{l || " "}</div>
          ))}
        </>
      )}
    </div>
  );
}

/** 충돌 블록 하나: 왼쪽 내 것, 오른쪽 상대 것, 아래 고르기 */
function BlockCard({ store, block, sides }: { store: RepoStore; block: ConflictBlock; sides: { ours: string; theirs: string } }) {
  const choice = store.conflictChoices.get(block.id);
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState("");
  return (
    <div className={`conflict-block ${choice ? "done" : ""}`}>
      {choice && !editing ? (
        <>
          <div className="row" style={{ gap: 6 }}>
            <Check size={14} style={{ color: "var(--green)" }} />
            <span style={{ fontWeight: 600, color: "var(--green)" }}>{t("Chosen: {0}", choiceTitle(choice))}</span>
            <span className="spacer" />
            <Button size="small" onClick={() => store.chooseConflict(block.id, null)}>
              {t("Choose again")}</Button>
          </div>
          <Code lines={choiceLines(block, choice)} tone="chosen" />
        </>
      ) : editing ? (
        <>
          <span style={{ fontWeight: 600 }}>{t("Edit manually")}</span>
          <textarea className="conflict-edit" value={text} onChange={(e) => setText(e.target.value)} spellCheck={false} />
          <div className="row" style={{ gap: 6, justifyContent: "flex-end" }}>
            <Button size="small" onClick={() => setEditing(false)}>
              {t("Cancel")}</Button>
            <Button
              size="small"
              kind="primary"
              onClick={() => {
                store.chooseConflict(block.id, { kind: "custom", text });
                setEditing(false);
              }}
            >
              {t("Use this")}</Button>
          </div>
        </>
      ) : (
        <>
          <div className="conflict-sides">
            <Side title={t("Mine · {0}", sides.ours)} label={block.oursLabel} lines={block.ours} tone="ours" />
            <Side title={t("Theirs · {0}", sides.theirs)} label={block.theirsLabel} lines={block.theirs} tone="theirs" />
          </div>
          <div className="row" style={{ gap: 6 }}>
            <Button size="small" onClick={() => store.chooseConflict(block.id, { kind: "ours" })}>
              {t("Mine")}</Button>
            <Button size="small" onClick={() => store.chooseConflict(block.id, { kind: "theirs" })}>
              {t("Theirs")}</Button>
            <Button
              size="small"
              onClick={(e) =>
                showMenuBelow(e.currentTarget, [
                  { label: t("Mine first"), onClick: () => store.chooseConflict(block.id, { kind: "oursThenTheirs" }) },
                  { label: t("Theirs first"), onClick: () => store.chooseConflict(block.id, { kind: "theirsThenOurs" }) },
                ])
              }
            >
              {t("Both")}{" "}<ChevronDown size={12} />
            </Button>
            <Button
              size="small"
              onClick={() => {
                setText([...block.ours, ...block.theirs].join("\n"));
                setEditing(true);
              }}
            >
              {t("Edit manually…")}</Button>
          </div>
        </>
      )}
    </div>
  );
}

function Side({ title, label, lines, tone }: { title: string; label: string; lines: string[]; tone: "ours" | "theirs" }) {
  return (
    <div className={`conflict-side ${tone}`}>
      <span className="conflict-side-title" data-tip={label ? `${title}|${label}` : title}>
        {title}
      </span>
      <Code lines={lines} tone={tone} />
    </div>
  );
}

function Code({ lines, tone }: { lines: string[]; tone: "ours" | "theirs" | "chosen" }) {
  return (
    <div className={`conflict-code ${tone}`}>
      {lines.length ? lines.map((l, i) => <div key={i}>{l || " "}</div>) : <div className="muted">{t("(empty)")}</div>}
    </div>
  );
}
