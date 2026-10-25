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
  segments: ConflictSegment[];
  blocks: ConflictBlock[];
  /** 줄 끝(원래 파일이 CRLF 면 그대로 쓴다) */
  newline: string;
  trailingNewline: boolean;
}

export function parseConflict(text: string): ConflictDocument {
  const doc: ConflictDocument = { segments: [], blocks: [], newline: text.includes("\r\n") ? "\r\n" : "\n", trailingNewline: false };
  let body = text.replace(/\r\n/g, "\n");
  doc.trailingNewline = body.endsWith("\n");
  if (doc.trailingNewline) body = body.slice(0, -1);
  let state: "normal" | "ours" | "base" | "theirs" = "normal";
  let plain: string[] = [],
    ours: string[] = [],
    base: string[] | null = null,
    theirs: string[] = [],
    oursLabel = "";
  let width = 7;
  let pending: string[] = [];
  const label = (line: string, marker: string) => {
    if (!line.startsWith(marker.repeat(width))) return null;
    const rest = line.slice(width);
    return !rest || /^[ \t]/.test(rest) ? rest.trim() : null;
  };
  for (const line of body.split("\n")) {
    if (state !== "normal") pending.push(line);
    if (state === "normal") {
      const start = line.match(/^(<{7,})(?:[ \t](.*))?$/);
      if (start) {
        if (plain.length) doc.segments.push({ kind: "text", lines: plain });
        plain = [];
        width = start[1].length;
        oursLabel = (start[2] ?? "").trim();
        pending = [line];
        ours = [];
        base = null;
        theirs = [];
        state = "ours";
      } else plain.push(line);
    } else if (state === "ours") {
      if (label(line, "|") !== null) {
        base = [];
        state = "base";
      } else if (line === "=".repeat(width)) state = "theirs";
      else ours.push(line);
    } else if (state === "base") {
      if (line === "=".repeat(width)) state = "theirs";
      else base!.push(line);
    } else if (label(line, ">") !== null) {
      const id = doc.blocks.length;
      doc.blocks.push({ id, oursLabel, theirsLabel: label(line, ">")!, ours, base, theirs });
      doc.segments.push({ kind: "conflict", block: id });
      state = "normal";
      pending = [];
    } else theirs.push(line);
  }
  // 닫히지 않은 표시는 글로 돌려놓는다
  if (state !== "normal") plain.push(...pending);
  if (plain.length) doc.segments.push({ kind: "text", lines: plain });
  return doc;
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
  if (!doc.blocks.every((b) => choices.has(b.id))) return null;
  const out: string[] = [];
  for (const s of doc.segments) out.push(...(s.kind === "text" ? s.lines : choiceLines(doc.blocks[s.block], choices.get(s.block)!)));
  return out.join(doc.newline) + (doc.trailingNewline ? doc.newline : "");
}

export const choiceTitle = (c: ConflictChoice) =>
  ({ ours: t("Mine"), theirs: t("Theirs"), oursThenTheirs: t("Both (mine first)"), theirsThenOurs: t("Both (theirs first)"), custom: t("Edited manually") })[c.kind];
