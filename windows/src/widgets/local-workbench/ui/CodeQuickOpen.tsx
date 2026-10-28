import { useEffect, useId, useMemo, useRef, useState } from "react";
import { File, Search, X } from "lucide-react";
import type { RepositoryTreeEntry } from "@/entities/git";
import { t } from "@/shared/i18n";
import { rankCodeFiles } from "../lib/code-navigation";

interface Props { entries: RepositoryTreeEntry[]; recent: string[]; open: (entry: RepositoryTreeEntry) => void; close: () => void }

/** Keyboard-first file picker with a bounded result list and session-only recents. */
export function CodeQuickOpen({ entries, recent, open, close }: Props) {
  const [query, setQuery] = useState(""), [active, setActive] = useState(0);
  const input = useRef<HTMLInputElement>(null), closeButton = useRef<HTMLButtonElement>(null), list = useRef<HTMLDivElement>(null), id = useId();
  const results = useMemo(() => rankCodeFiles(entries, query, recent), [entries, query, recent]);
  const index = results.length ? Math.min(active, results.length - 1) : 0;
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    input.current?.focus();
    return () => { if (previous?.isConnected) previous.focus(); };
  }, []);
  useEffect(() => { list.current?.querySelector<HTMLElement>(`[data-index="${index}"]`)?.scrollIntoView({ block: "nearest" }); }, [index, results]);
  const choose = (entry: RepositoryTreeEntry) => { close(); open(entry); };
  return <div className="modal-backdrop code-quick-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) close(); }}>
    <div className="code-quick-open" role="dialog" aria-modal="true" aria-label={t("Quick open")} onKeyDown={(event) => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); }
      if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); event.stopPropagation(); setActive((value) => results.length ? (value + (event.key === "ArrowDown" ? 1 : -1) + results.length) % results.length : 0); }
      if (event.key === "Enter" && event.target === input.current) { event.preventDefault(); event.stopPropagation(); if (results[index]) choose(results[index]); }
      if (event.key === "Tab") { event.preventDefault(); if (document.activeElement === input.current) closeButton.current?.focus(); else input.current?.focus(); }
    }}>
      <div className="code-quick-heading"><strong>{t("Quick open")}</strong><button ref={closeButton} type="button" className="icon-btn" aria-label={t("Close quick open")} data-tip={t("Close quick open")} onClick={close}><X size={16}/></button></div>
      <label className="code-quick-search"><Search size={18}/><input ref={input} role="combobox" aria-expanded="true" aria-controls={`${id}-results`} aria-activedescendant={results[index] ? `${id}-${index}` : undefined} aria-label={t("Search files by name or path")} placeholder={t("Search files by name or path")} value={query} onChange={(event) => { setQuery(event.target.value); setActive(0); }}/></label>
      <div className="code-quick-section">{t(query.trim() ? "Files" : "Recent files")}</div>
      <div ref={list} className="code-quick-results" role="listbox" id={`${id}-results`} aria-label={t("Files")}>{results.map((entry, i) => <button type="button" role="option" aria-selected={i === index} tabIndex={-1} id={`${id}-${i}`} key={entry.path} data-index={i} className={i === index ? "on" : ""} onMouseMove={() => setActive(i)} onClick={() => choose(entry)}><File size={16}/><span><strong>{entry.path.split("/").at(-1)}</strong><small>{entry.path}</small></span>{i === index && <kbd>↵</kbd>}</button>)}{!results.length && <div className="code-quick-empty">{t("No matching files")}</div>}</div>
      <footer><span>↑ ↓</span><span>↵</span><span>Esc</span></footer>
    </div>
  </div>;
}
