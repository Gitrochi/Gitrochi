import { useEffect, useMemo, useState } from "react";
import { avatars } from "@/entities/avatar";
import { isUncommittedLine, short, type BlameLine } from "@/entities/git";
import { t } from "@/shared/i18n";
import { shortDate, useObserve } from "@/shared/lib";
import { Avatar } from "@/shared/ui";
import { hangingIndent } from "./CodeChangesView";

interface Props {
  lines: BlameLine[];
  wrap: boolean;
  show: (commit: string) => void;
  /** Blames the file as it was before a commit; null when its history does not reach an older commit */
  before: (commit: string) => (() => void) | null;
}

/**
 * The Blame view of the Code page: every line with the commit that last changed it. Consecutive lines from one commit
 * form a group that names the commit once, in a 280px gutter; a 1px line separates the groups, and no stripes, which
 * read as hover. (macOS: RepositoryCodeBlameView)
 */
export function CodeBlameView({ lines, wrap, show, before }: Props) {
  useObserve(avatars);
  // the first line of the group whose commit card is open
  const [opened, setOpened] = useState<number | null>(null);
  const groups = useMemo(() => {
    const result: BlameLine[][] = [];
    for (const line of lines) { if (line.startsBlock || !result.length) result.push([line]); else result.at(-1)!.push(line); }
    return result;
  }, [lines]);
  useEffect(() => {
    if (opened == null) return;
    const close = (event: Event) => { if (event instanceof KeyboardEvent ? event.key === "Escape" : !(event.target as Element | null)?.closest?.(".code-blame-card, .code-blame-commit")) setOpened(null); };
    document.addEventListener("mousedown", close); document.addEventListener("keydown", close);
    return () => { document.removeEventListener("mousedown", close); document.removeEventListener("keydown", close); };
  }, [opened]);
  return <section className={`code-blame ${wrap ? "wrap" : ""}`} aria-label={t("Blame")} tabIndex={0}>
    <div className="code-blame-sheet">
      {groups.map((group) => {
        const first = group[0], open = opened === first.no, earlier = open ? before(first.sha) : null;
        // the whole group answers to the pointer, gutter and code alike
        return <div className={`code-blame-group ${open ? "open" : ""}`} key={first.no}>
          {group.map((line, index) => <div className="code-blame-line" key={line.no}>
            <span className="code-blame-gutter">{index === 0 && (isUncommittedLine(line)
              ? <span className="code-blame-note">{t("Not committed")}</span>
              : <button type="button" className="code-blame-commit" aria-haspopup="dialog" aria-expanded={open} aria-label={`${t("Commit")} ${short(line.sha)}, ${line.summary}`} onClick={() => setOpened(open ? null : line.no)}>
                <Avatar name={line.author} email={line.email} size={16} url={avatars.url(line.email, line.author)}/>
                <span className="ellipsis">{line.summary}</span>
                <span className="code-blame-age">{shortDate(line.date)}</span>
              </button>)}</span>
            <span className="no">{line.no}</span>
            <span className="code" style={hangingIndent(line.text, wrap)}>{line.text || " "}</span>
          </div>)}
          {open && <div className="code-blame-card" role="dialog" aria-label={`${t("Commit")} ${short(first.sha)}`}>
            <span className="code-blame-who"><Avatar name={first.author} email={first.email} size={20} url={avatars.url(first.email, first.author)}/><strong className="ellipsis">{first.author}</strong><span className="code-blame-age">{shortDate(first.date)}</span></span>
            <strong className="code-blame-subject">{first.summary}</strong>
            <code className="selectable">{short(first.sha)}</code>
            <span className="code-blame-actions">
              <button type="button" className="code-text-button" onClick={() => { setOpened(null); show(first.sha); }}>{t("Show commit")}</button>
              {earlier && <button type="button" className="code-text-button" onClick={() => { setOpened(null); earlier(); }}>{t("Blame before this change")}</button>}
            </span>
          </div>}
        </div>;
      })}
    </div>
  </section>;
}
