import { Fragment, useEffect, useMemo, useRef, type ReactNode } from "react";
import { sourceTokens, wrappingLineLimit, type SourceMatch } from "../lib/source-reader";
import { codeLineRange } from "../lib/code-navigation";

interface Props {
  text: string;
  language: string;
  fontSize: number;
  wrap: boolean;
  matches: SourceMatch[];
  activeMatch: number;
  lineCount: number;
  jump: { line: number; id: number } | null;
}

/** Selectable source with bounded syntax spans and a gutter outside the accessible text. */
export function RepositorySourceView({ text, language, fontSize, wrap, matches, activeMatch, lineCount, jump }: Props) {
  const host = useRef<HTMLPreElement>(null);
  const tokens = useMemo(() => sourceTokens(text, language), [text, language]);
  const content = useMemo(() => {
    const large = lineCount > wrappingLineLimit;
    const jumpRange = large && jump ? codeLineRange(text, jump.line) : null;
    const bounds = [...new Set([0, text.length, ...tokens.flatMap((token) => [token.start, token.end]), ...matches.flatMap((match) => [match.start, match.end]), ...(jumpRange ? [jumpRange.start, jumpRange.end] : [])])].sort((a, b) => a - b);
    const lines: ReactNode[][] = [[]];
    let tokenIndex = 0, matchIndex = 0;
    for (let i = 0; i < bounds.length - 1; i++) {
      const start = bounds[i], end = bounds[i + 1];
      while (tokenIndex < tokens.length && tokens[tokenIndex].end <= start) tokenIndex++;
      while (matchIndex < matches.length && matches[matchIndex].end <= start) matchIndex++;
      const kind = tokens[tokenIndex]?.start <= start ? tokens[tokenIndex].kind : "";
      const found = matches[matchIndex]?.start <= start && matches[matchIndex]?.end >= end;
      const segments = large ? [text.slice(start, end)] : text.slice(start, end).split("\n");
      for (let part = 0; part < segments.length; part++) {
        if (part) lines.push([]);
        const value = segments[part];
        if (!value) continue;
        const key = `${i}-${part}`, className = kind ? `source-${kind}` : undefined;
        const node = found
          ? <mark key={key} data-match={matchIndex} className={matchIndex === activeMatch ? "active" : undefined}><span className={className}>{value}</span></mark>
          : className ? <span key={key} className={className}>{value}</span> : <Fragment key={key}>{value}</Fragment>;
        lines.at(-1)!.push(jumpRange && start >= jumpRange.start && end <= jumpRange.end ? <span className="source-line-jump" data-line-jump={jump!.line} key={`jump-${key}`}>{node}</span> : node);
      }
    }
    if (large) return <><span className="source-gutter" aria-hidden="true">{Array.from({ length: lineCount }, (_, i) => i + 1).join("\n")}</span><code className="source-large-text">{lines[0]}</code></>;
    if (text.endsWith("\n") && lines.length > 1) lines.pop();
    return lines.map((line, index) => <span className={`source-row ${jump?.line === index + 1 ? "source-line-jump" : ""}`} data-line={index + 1} data-line-jump={jump?.line === index + 1 ? index + 1 : undefined} key={index}><span className="source-line-number" aria-hidden="true">{index + 1}</span><span className="source-line-text">{line}{index < lines.length - 1 || text.endsWith("\n") ? "\n" : ""}</span></span>);
  }, [text, tokens, matches, activeMatch, lineCount, jump]);
  useEffect(() => { if (host.current) { host.current.scrollTop = 0; host.current.scrollLeft = 0; } }, [text]);
  useEffect(() => {
    host.current?.querySelector<HTMLElement>(`mark[data-match="${activeMatch}"]`)?.scrollIntoView({ block: "center", inline: "nearest" });
  }, [matches, activeMatch]);
  useEffect(() => { if (jump) host.current?.querySelector<HTMLElement>("[data-line-jump]")?.scrollIntoView({ block: "center", inline: "nearest" }); }, [jump, wrap, fontSize]);
  return <pre ref={host} className={`repository-source ${wrap && lineCount <= wrappingLineLimit ? "wrap" : ""} ${lineCount > wrappingLineLimit ? "large" : ""}`} style={{ fontSize }} tabIndex={0}>{content}</pre>;
}
