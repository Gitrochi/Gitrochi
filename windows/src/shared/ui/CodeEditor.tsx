import { Redo2, Save, Undo2, WrapText } from "lucide-react";
import { ArrowDown, ArrowUp, Minus, Plus, Search, X } from "@/shared/icons";
import { type CSSProperties, type ReactNode, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { applyEditorText, editorLineRange, editorText, indentEditorText, sourceLanguage, sourceMatches, sourceTokens, wrappingLineLimit } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { IconButton } from "./ui";
import "./code-editor.css";

interface Snapshot { text: string; start: number; end: number }
interface Props { value: string; onChange: (text: string) => void; label: string; fileName: string; documentKey: string; onSave?: () => void; readOnly?: boolean; jumpLine?: number | null; jumpRequest?: number }

/** Small source editor sharing the repository reader's bounded syntax and literal search. */
export function CodeEditor({ value, onChange, label, fileName, documentKey, onSave, readOnly = false, jumpLine, jumpRequest }: Props) {
  const area = useRef<HTMLTextAreaElement>(null), syntax = useRef<HTMLPreElement>(null), gutter = useRef<HTMLPreElement>(null), findInput = useRef<HTMLInputElement>(null), lineInput = useRef<HTMLInputElement>(null);
  const source = editorText(value), language = sourceLanguage(fileName), lines = source.split("\n").length;
  const [fontSize, setFontSize] = useState(12), [goOpen, setGoOpen] = useState(false), [lineNumber, setLineNumber] = useState(""), [invalidLine, setInvalidLine] = useState(false);
  const [findOpen, setFindOpen] = useState(false), [query, setQuery] = useState(""), [replacement, setReplacement] = useState(""), [active, setActive] = useState(0), [wrap, setWrap] = useState(false);
  const [position, setPosition] = useState({ line: 1, column: 1 }), [revision, setRevision] = useState(0), [heights, setHeights] = useState<number[]>([]);
  const history = useRef<{ key: string; entries: Snapshot[]; index: number }>({ key: documentKey, entries: [{ text: value, start: 0, end: 0 }], index: 0 });
  const current = useRef(value); current.current = value;
  const matches = useMemo(() => sourceMatches(source, query), [source, query]);
  const wrapped = wrap && lines <= wrappingLineLimit;
  const rendered = useMemo(() => {
    if (lines > wrappingLineLimit) return source;
    const rows: ReactNode[][] = [[]]; let offset = 0, key = 0;
    const append = (text: string, kind?: string) => text.split("\n").forEach((part, index) => { if (index) rows.push([]); if (part) rows.at(-1)!.push(kind ? <span key={key++} className={`code-token-${kind}`}>{part}</span> : part); });
    for (const token of sourceTokens(source, language)) { append(source.slice(offset, token.start)); append(source.slice(token.start, token.end), token.kind); offset = token.end; }
    append(source.slice(offset));
    return rows.map((row, index) => <span className="code-editor-row" key={index}>{row.length ? row : "\u200b"}</span>);
  }, [source, language, lines]);
  const bump = () => setRevision((number) => number + 1);
  const record = (text: string, start: number, end: number) => {
    const state = history.current;
    state.entries = state.entries.slice(0, state.index + 1);
    if (state.entries.at(-1)?.text === text) return;
    state.entries.push({ text, start, end });
    let total = state.entries.reduce((sum, entry) => sum + entry.text.length, 0);
    while (state.entries.length > 2 && (state.entries.length > 120 || total > 8_000_000)) total -= state.entries.shift()!.text.length;
    state.index = state.entries.length - 1; bump();
  };
  useEffect(() => {
    if (history.current.key !== documentKey) { history.current = { key: documentKey, entries: [{ text: value, start: 0, end: 0 }], index: 0 }; setQuery(""); setActive(0); bump(); }
    else if (history.current.entries[history.current.index].text !== value) record(value, area.current?.selectionStart ?? 0, area.current?.selectionEnd ?? 0);
  }, [documentKey, value]);
  const selection = (start: number, end: number, focus = true) => requestAnimationFrame(() => { const element = area.current; if (!element) return; if (focus) element.focus(); element.setSelectionRange(start, end); const line = source.slice(0, start).split("\n").length; element.scrollTop = Math.max(0, (line - 1) * (fontSize + 8) - element.clientHeight / 2); syncScroll(); });
  const commit = (text: string, start: number, end = start) => { if (readOnly) return; const raw = applyEditorText(current.current, text); current.current = raw; record(raw, start, end); onChange(raw); selection(start, end); };
  const stepHistory = (direction: -1 | 1) => {
    if (readOnly) return;
    const state = history.current, index = state.index + direction;
    if (index < 0 || index >= state.entries.length) return;
    state.index = index; const entry = state.entries[index]; current.current = entry.text; onChange(entry.text); selection(entry.start, entry.end); bump();
  };
  const syncScroll = () => { const element = area.current; if (!element) return; if (syntax.current) { syntax.current.scrollTop = element.scrollTop; syntax.current.scrollLeft = element.scrollLeft; } if (gutter.current) gutter.current.scrollTop = element.scrollTop; };
  useLayoutEffect(() => {
    const measure = () => { if (!area.current || !syntax.current) return; syntax.current.style.width = `${area.current.clientWidth}px`; if (wrapped) { const next = [...syntax.current.querySelectorAll<HTMLElement>(".code-editor-row")].map((row) => row.getBoundingClientRect().height); setHeights((previous) => previous.length === next.length && previous.every((height, index) => height === next[index]) ? previous : next); } syncScroll(); };
    measure(); const observer = new ResizeObserver(measure); if (area.current) observer.observe(area.current); return () => observer.disconnect();
  }, [value, wrapped, rendered, fontSize]);
  useEffect(() => { if (jumpLine) { const range = editorLineRange(source, jumpLine); selection(range.start, range.end); } }, [jumpLine, jumpRequest]);
  const find = (direction = 1) => { if (!matches.length) return; const next = (active + direction + matches.length) % matches.length; setActive(next); selection(matches[next].start, matches[next].end); };
  const showFind = () => { setFindOpen(true); requestAnimationFrame(() => { findInput.current?.focus(); findInput.current?.select(); }); };
  useEffect(() => { setActive(0); if (matches[0]) selection(matches[0].start, matches[0].end, false); }, [query]);
  const replaceOne = () => { const match = matches[Math.min(active, matches.length - 1)]; if (match) commit(source.slice(0, match.start) + replacement + source.slice(match.end), match.start + replacement.length); };
  const replaceAll = () => { if (!query) return; const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "giu"); commit(source.replace(pattern, () => replacement), 0); };
  const showLine = () => { setGoOpen(true); setLineNumber(String(position.line)); setInvalidLine(false); requestAnimationFrame(() => { lineInput.current?.focus(); lineInput.current?.select(); }); };
  const state = history.current; void revision;
  return <section className="code-editor" data-code-editor data-search-open={findOpen || goOpen} style={{ "--code-font-size": `${fontSize}px`, "--code-line-height": `${fontSize + 8}px` } as CSSProperties} onKeyDown={(event) => { if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "l") { event.preventDefault(); event.stopPropagation(); showLine(); } if (event.key === "Escape" && (findOpen || goOpen)) { event.preventDefault(); event.stopPropagation(); setFindOpen(false); setGoOpen(false); } }}>
    <header className="code-editor-toolbar"><code title={fileName}>{fileName}</code><span className="spacer" /><IconButton small icon={<Undo2 size={13} />} tip={t("Undo")} aria-label={t("Undo")} disabled={readOnly || state.index === 0} onClick={() => stepHistory(-1)} /><IconButton small icon={<Redo2 size={13} />} tip={t("Redo")} aria-label={t("Redo")} disabled={readOnly || state.index >= state.entries.length - 1} onClick={() => stepHistory(1)} /><IconButton small icon={<Search size={13} />} tip={t("Find in code")} aria-label={t("Find in code")} onClick={showFind} /><IconButton small icon={<WrapText size={13} />} className={wrapped ? "on" : ""} tip={t("Wrap lines")} aria-label={t("Wrap lines")} disabled={lines > wrappingLineLimit} onClick={() => setWrap((enabled) => !enabled)} />{onSave && <IconButton small icon={<Save size={13} />} tip={t("Save")} aria-label={t("Save")} disabled={readOnly} onClick={onSave} />}</header>
    {findOpen && <div className="code-editor-find"><input ref={findInput} aria-label={t("Find in code")} placeholder={t("Find in code")} value={query} onChange={(event) => setQuery(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); find(event.shiftKey ? -1 : 1); } }} /><span>{matches.length ? `${Math.min(active + 1, matches.length)}/${matches.length}` : "0"}</span><IconButton small icon={<ArrowUp size={12} />} tip={t("Previous match")} onClick={() => find(-1)} /><IconButton small icon={<ArrowDown size={12} />} tip={t("Next match")} onClick={() => find(1)} /><IconButton small icon={<X size={12} />} tip={t("Close search")} onClick={() => setFindOpen(false)} /><input aria-label={t("Replace with")} placeholder={t("Replace with")} value={replacement} onChange={(event) => setReplacement(event.target.value)} /><button type="button" disabled={readOnly || !matches.length} onClick={replaceOne}>{t("Replace")}</button><button type="button" disabled={readOnly || !matches.length} onClick={replaceAll}>{t("Replace all")}</button></div>}
    {goOpen && <form className="code-editor-go-line" onSubmit={(event) => { event.preventDefault(); const line = Number(lineNumber); if (!Number.isSafeInteger(line) || line < 1 || line > lines) { setInvalidLine(true); return; } const range = editorLineRange(source, line); setGoOpen(false); selection(range.start, range.end); }}><input ref={lineInput} aria-label={t("Line number")} inputMode="numeric" value={lineNumber} onChange={(event) => { setLineNumber(event.target.value); setInvalidLine(false); }} /><button type="submit">{t("Go to line")}</button>{invalidLine && <span role="alert">{t("Enter a line from 1 to {0}.", lines)}</span>}</form>}
    <div className={`code-editor-body ${wrapped ? "wrap" : ""}`}><pre ref={gutter} className="code-editor-gutter" aria-hidden="true">{wrapped ? Array.from({ length: lines }, (_, index) => <span key={index} style={{ height: heights[index] ?? 20 }}>{index + 1}</span>) : Array.from({ length: lines }, (_, index) => index + 1).join("\n")}</pre><div className="code-editor-surface"><pre ref={syntax} aria-hidden="true" className="code-editor-syntax"><code>{rendered}</code></pre><textarea ref={area} aria-label={label} value={source} readOnly={readOnly} wrap={wrapped ? "soft" : "off"} autoCapitalize="off" autoCorrect="off" spellCheck={false} onScroll={syncScroll} onBeforeInput={() => { const element = area.current; if (element) Object.assign(history.current.entries[history.current.index], { start: element.selectionStart, end: element.selectionEnd }); }} onSelect={(event) => { const at = event.currentTarget.selectionStart, before = source.slice(0, at); setPosition({ line: before.split("\n").length, column: at - (at > 0 ? source.lastIndexOf("\n", at - 1) : -1) }); }} onChange={(event) => { const element = event.currentTarget, raw = applyEditorText(current.current, element.value); current.current = raw; record(raw, element.selectionStart, element.selectionEnd); onChange(raw); }} onKeyDown={(event) => {
      const modifier = event.ctrlKey || event.metaKey;
      if (modifier && event.key.toLowerCase() === "s") { event.preventDefault(); onSave?.(); }
      else if (modifier && ["f", "h"].includes(event.key.toLowerCase())) { event.preventDefault(); showFind(); }
      else if (modifier && event.key.toLowerCase() === "z") { event.preventDefault(); stepHistory(event.shiftKey ? 1 : -1); }
      else if (modifier && event.key.toLowerCase() === "y") { event.preventDefault(); stepHistory(1); }
      else if (event.key === "Tab" && !readOnly) { event.preventDefault(); const element = event.currentTarget, changed = indentEditorText(source, element.selectionStart, element.selectionEnd, event.shiftKey); commit(changed.text, changed.start, changed.end); }
      else if (event.key === "Escape" && findOpen) { event.preventDefault(); event.stopPropagation(); setFindOpen(false); }
    }} /></div></div>
    <footer className="code-editor-status"><button type="button" onClick={showLine} data-tip={t("Go to line")}>{t("Line {0}, column {1}", position.line, position.column)}</button><span className="spacer" /><IconButton small icon={<Minus size={11} />} tip={t("Decrease font size")} aria-label={t("Decrease font size")} disabled={fontSize <= 10} onClick={() => setFontSize((size) => Math.max(10, size - 1))} /><span>{fontSize}</span><IconButton small icon={<Plus size={11} />} tip={t("Increase font size")} aria-label={t("Increase font size")} disabled={fontSize >= 20} onClick={() => setFontSize((size) => Math.min(20, size + 1))} /><span>{language}</span><span>{value.includes("\r\n") ? "CRLF" : "LF"}</span><span>UTF-8</span></footer>
  </section>;
}
