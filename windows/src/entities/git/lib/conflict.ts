import { runCore } from "@/shared/core";
import { t } from "@/shared/i18n";
/** 충돌 난 파일: 충돌 표시(<<<<<<< ======= >>>>>>>) 사이를 블록으로 나눈 것 (맥 버전 Core/Conflict.swift) */

export interface ConflictBlock {
  id: number;
  /** <<<<<<< 뒤의 이름(HEAD 등) */
  oursLabel: string;
  theirsLabel: string;
  ours: string[];
  /** diff3 형식이면 공통 조상(||||||| 와 ======= 사이) */
  base: string[] | null;
  theirs: string[];
}

export type ConflictSegment = { kind: "text"; lines: string[] } | { kind: "conflict"; block: number };

/** 블록마다 고르는 것 */
export type ConflictChoice = { kind: "ours" } | { kind: "theirs" } | { kind: "oursThenTheirs" } | { kind: "theirsThenOurs" } | { kind: "custom"; text: string };

export interface ConflictDocument {
  sourceText: string;
  baseText?: string;
  indexSignature?: string;
  segments: ConflictSegment[];
  blocks: ConflictBlock[];
  /** 줄 끝(원래 파일이 CRLF 면 그대로 쓴다) */
  newline: string;
  trailingNewline: boolean;
}

export function parseConflict(text: string): ConflictDocument {
  return runCore({ op: "conflict", text });
}

export function choiceLines(b: ConflictBlock, c: ConflictChoice): string[] {
  switch (c.kind) {
    case "ours":
      return b.ours;
    case "theirs":
      return b.theirs;
    case "oursThenTheirs":
      return [...b.ours, ...b.theirs];
    case "theirsThenOurs":
      return [...b.theirs, ...b.ours];
    case "custom":
      return c.text ? c.text.replace(/\r\n/g, "\n").split("\n") : [];
  }
}

/** 고른 대로 합친 파일 내용(모든 블록을 골랐을 때만) */
export function resolveConflict(doc: ConflictDocument, choices: Map<number, ConflictChoice>): string | null {
  return runCore({ op: "resolveConflict", doc, choices: Object.fromEntries(choices) });
}

/** 전체 파일을 나란히 보되 미선택 블록의 표시는 결과에 남겨 실수로 해결 처리하지 않는다. */
export function conflictProjection(doc: ConflictDocument, side: "ours" | "theirs" | "base" | "result", choices = new Map<number, ConflictChoice>()): string {
  if (side === "base" && doc.baseText !== undefined) return doc.baseText;
  const out: string[] = [];
  for (const segment of doc.segments) {
    if (segment.kind === "text") { out.push(...segment.lines); continue; }
    const b = doc.blocks[segment.block];
    if (side === "ours") out.push(...b.ours);
    else if (side === "theirs") out.push(...b.theirs);
    else if (side === "base") out.push(...(b.base ?? [t("Common ancestor is unavailable for this block.")]));
    else if (choices.has(b.id)) out.push(...choiceLines(b, choices.get(b.id)!));
    else out.push(`<<<<<<< ${b.oursLabel}`, ...b.ours, "=======", ...b.theirs, `>>>>>>> ${b.theirsLabel}`);
  }
  return out.join(doc.newline) + (doc.trailingNewline ? doc.newline : "");
}

export const choiceTitle = (c: ConflictChoice) =>
  ({ ours: t("Mine"), theirs: t("Theirs"), oursThenTheirs: t("Both (mine first)"), theirsThenOurs: t("Both (theirs first)"), custom: t("Edited manually") })[c.kind];
