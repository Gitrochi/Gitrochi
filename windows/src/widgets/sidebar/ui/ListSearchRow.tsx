import { Funnel, Search, X } from "lucide-react";
import { t } from "@/shared/i18n";
import { showMenuBelow } from "@/shared/ui";

/**
 * The repository sidebar's stand-in for the search row: one line saying how the shared list is filtered, with a
 * button that goes back to open items and no search. Searching and filtering happen on the list's page.
 */
export function ListFilterCaption({ state, search, onClear }: { state: string; search: string; onClear: () => void }) {
  const text = t("Filtered: {0}", state + (search ? ` · “${search}”` : ""));
  return (
    <div className="list-filter-caption" title={text}>
      <Funnel size={12} fill="currentColor" />
      <span className="ellipsis">{text}</span>
      <button type="button" className="list-search-clear" aria-label={t("Clear filter")} data-tip={t("Clear filter")} onClick={onClear}><X size={12} /></button>
    </div>
  );
}

/**
 * A list's search field with a magnifier inside and a clear button, and a filter icon beside it that opens the
 * filter choices; the icon fills while a filter other than the default is on. Enter searches, clearing searches again.
 * (macOS: ListSearchRow in ListSearchField.swift)
 */
export function ListSearchRow<T extends string>({ prompt, text, onText, filters, selection, defaultFilter, onSearch, onFilter }: {
  prompt: string;
  text: string;
  onText: (text: string) => void;
  filters: { value: T; title: string }[];
  selection: T;
  defaultFilter: T;
  onSearch: (text: string) => void;
  onFilter: (value: T) => void;
}) {
  const filtered = selection !== defaultFilter;
  const clear = () => { onText(""); onSearch(""); };
  return (
    <div className="list-search-row">
      <div className="list-search-field">
        <Search size={12} className="muted" />
        <input
          value={text}
          placeholder={prompt}
          aria-label={prompt}
          onChange={(e) => onText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") { e.preventDefault(); onSearch(text); }
            if (e.key === "Escape" && text) { e.preventDefault(); e.stopPropagation(); clear(); }
          }}
        />
        {text && <button type="button" className="list-search-clear" aria-label={t("Clear search")} data-tip={t("Clear search")} onClick={clear}><X size={12} /></button>}
      </div>
      <button
        type="button"
        className={`list-filter-button${filtered ? " on" : ""}`}
        aria-label={t("Filter")}
        data-tip={`${t("Filter")}: ${filters.find((f) => f.value === selection)?.title ?? ""}`}
        onClick={(e) => showMenuBelow(e.currentTarget, filters.map((f) => ({ label: f.title, checked: f.value === selection, onClick: () => onFilter(f.value) })))}
      >
        <Funnel size={14} fill={filtered ? "currentColor" : "none"} />
      </button>
    </div>
  );
}
