import { FileText, type LucideIcon, MessageCircleQuestion, Search, Tag, Waypoints } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { type LedgerSearchHit, type LedgerSearchKind, type LedgerStore, stepIndex } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { Modal, Spinner } from "@/shared/ui";

const kinds: Record<LedgerSearchKind, { icon: LucideIcon; label: string }> = { session: { icon: Waypoints, label: "Session" }, question: { icon: MessageCircleQuestion, label: "Question" }, event: { icon: FileText, label: "Report" }, baseline: { icon: Tag, label: "Baseline" } };

/**
 * Ctrl+K: finds sessions, questions, report summaries and bodies, and baselines through the backend's `search`, so
 * report bodies never have to be loaded into the page. ↑ ↓ and Enter open a result; a report opens its session at
 * that report. Windows has no workspace command palette yet, so this search lives inside the Ledger.
 * (macOS: the Ledger group of WorkspaceCommandPalette)
 */
export function LedgerSearch({ store, onClose, onPick }: { store: LedgerStore; onClose: () => void; onPick: (hit: LedgerSearchHit) => void }) {
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<LedgerSearchHit[]>([]);
  const [active, setActive] = useState(0);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const list = useRef<HTMLDivElement>(null);
  useEffect(() => {
    let live = true;
    const timer = setTimeout(() => {
      if (!query.trim()) { setHits([]); setLoading(false); return; }
      setLoading(true);
      store.search(query).then((found) => { if (live) { setHits(found); setActive(0); setError(null); } }, (e: unknown) => { if (live) setError(e instanceof Error ? e.message : String(e)); }).finally(() => { if (live) setLoading(false); });
    }, 120);
    return () => { live = false; clearTimeout(timer); };
  }, [query, store]);
  useEffect(() => {
    list.current?.querySelector(".ledger-hit.active")?.scrollIntoView({ block: "nearest" });
  }, [active]);
  const pick = (hit: LedgerSearchHit | undefined) => { if (hit) { onPick(hit); onClose(); } };
  const project = store.project ? store.state?.projects.find((p) => p.key === store.project)?.name ?? store.project : null;
  return (
    <Modal width={600} onClose={onClose}>
      <div className="ledger-filter-input" style={{ margin: 0 }}>
        <Search size={15} />
        <input
          className="input"
          autoFocus
          value={query}
          role="combobox"
          aria-expanded={hits.length > 0}
          aria-controls="ledger-search-results"
          aria-label={t("Search the Ledger")}
          placeholder={project ? t("Search sessions, questions and reports in {0}", project) : t("Search sessions, questions and reports")}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); setActive(stepIndex(active, e.key === "ArrowDown" ? 1 : -1, hits.length)); }
            else if (e.key === "Enter") { e.preventDefault(); pick(hits[active]); }
          }}
        />
      </div>
      <div className="ledger-search-results" id="ledger-search-results" role="listbox" ref={list}>
        {loading && !hits.length && <div className="row hint" style={{ padding: 10 }}><Spinner size={12} />{t("Searching…")}</div>}
        {error && <span className="error-text" style={{ padding: 10 }}>{error}</span>}
        {!loading && !error && query.trim() && !hits.length && <span className="hint" style={{ padding: 10 }}>{t("Nothing found")}</span>}
        {!query.trim() && <span className="hint" style={{ padding: 10 }}>{t("Session IDs, titles, questions, report text and versions. ↑ ↓ to move, Enter to open.")}</span>}
        {hits.map((hit, i) => {
          const look = kinds[hit.kind];
          return (
            <button key={`${hit.kind}:${hit.id}`} type="button" role="option" aria-selected={i === active} className={`ledger-hit${i === active ? " active" : ""}`} onMouseEnter={() => setActive(i)} onClick={() => pick(hit)}>
              <span className="ledger-hit-title"><look.icon size={13} className="muted" aria-label={t(look.label)} /><span>{hit.title}</span></span>
              {hit.snippet && <span className="ledger-hit-snippet">{hit.snippet}</span>}
            </button>
          );
        })}
      </div>
    </Modal>
  );
}
