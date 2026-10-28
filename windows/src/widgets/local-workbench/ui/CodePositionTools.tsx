import { useEffect, useRef, useState } from "react";
import { ListTree } from "lucide-react";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import type { CodeSymbol } from "../lib/code-navigation";

interface Props { lineCount: number; symbols: CodeSymbol[]; enabled: boolean; focusRequest: number; jump: (line: number) => void }

/** Compact line navigation and a declaration outline without a permanent third pane. */
export function CodePositionTools({ lineCount, symbols, enabled, focusRequest, jump }: Props) {
  const [lineInput, setLineInput] = useState(""), [invalid, setInvalid] = useState(false);
  const field = useRef<HTMLInputElement>(null), outline = useRef<HTMLDetailsElement>(null);
  useEffect(() => { setLineInput(""); setInvalid(false); if (outline.current) outline.current.open = false; }, [lineCount, symbols]);
  useEffect(() => { if (focusRequest) { field.current?.focus(); field.current?.select(); } }, [focusRequest]);
  return <div className="code-position-tools">
    <form className="code-go-line" onSubmit={(event) => {
      event.preventDefault();
      const line = /^\d+$/.test(lineInput.trim()) ? Number(lineInput.trim()) : 0;
      if (!Number.isSafeInteger(line) || line < 1 || line > lineCount) { setInvalid(true); field.current?.focus(); return; }
      setInvalid(false); jump(line);
    }}>
      <input ref={field} aria-label={t("Line number")} placeholder={t("Line number")} inputMode="numeric" value={lineInput} aria-invalid={invalid} disabled={!enabled || !lineCount} onChange={(event) => { setLineInput(event.target.value); setInvalid(false); }}/>
      <Button type="submit" size="small" disabled={!enabled || !lineCount}>{t("Go to line")}</Button>
      {invalid && <span className="code-line-error" role="alert">{t("Enter a line from 1 to {0}.", lineCount.toLocaleString())}</span>}
    </form>
    <details ref={outline} className="code-outline"><summary><ListTree size={14}/>{t("Outline")}<span>{symbols.length}</span></summary><div className="code-outline-list">{symbols.length ? symbols.map((symbol) => <button type="button" key={`${symbol.line}-${symbol.name}`} onClick={() => { jump(symbol.line); if (outline.current) outline.current.open = false; }}><span className={`code-symbol-kind ${symbol.kind}`}>{symbol.kind === "type" ? "T" : symbol.kind === "heading" ? "#" : "ƒ"}</span><span>{symbol.name}</span><small>{t("Line {0}", symbol.line)}</small></button>) : <p className="hint">{t("No symbols found")}</p>}</div></details>
  </div>;
}
