import type { CSSProperties, ReactNode } from "react";
import { sourceSegments, sourceTokens } from "@/shared/lib";
import "./code-text.css";

/**
 * One line of code in the code reader's colours, with optional changed-word marks (code point ranges, as a diff's word
 * changes are). Diffs, blame and file history use it. (macOS: RepositoryCodeReading.attributed)
 */
export function CodeText({ text, language, marks, markClassName, className, style }: {
  text: string;
  language: string;
  marks?: [number, number][];
  markClassName?: string;
  className?: string;
  style?: CSSProperties;
}) {
  const tokens = sourceTokens(text, language);
  if (!tokens.length && !marks?.length) return <span className={className} style={style}>{text}</span>;
  const parts: ReactNode[] = sourceSegments(text, tokens, marks ?? []).map((seg, k) => {
    const coloured = seg.kind ? <span key={k} className={`code-token-${seg.kind}`}>{seg.text}</span> : seg.text;
    return seg.mark ? <mark key={k} className={markClassName}>{coloured}</mark> : coloured;
  });
  return <span className={className} style={style}>{parts}</span>;
}
