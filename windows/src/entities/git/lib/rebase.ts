import { t } from "@/shared/i18n";
/** 인터랙티브 리베이스(커밋 정리) 계획 (맥 버전 Core/RebasePlan.swift 와 같은 규칙) */

export type RebaseAction = "pick" | "reword" | "squash" | "fixup" | "drop";

export const rebaseActions: Array<{ value: RebaseAction; title: string }> = [
  { value: "pick", title: t("Pick") },
  { value: "reword", title: t("Reword") },
  { value: "squash", title: t("Squash into the commit below") },
  { value: "fixup", title: t("Fixup into the commit below (discard message)") },
  { value: "drop", title: t("Drop") },
];

export interface RebaseItem {
  sha: string;
  subject: string;
  /** 원래 전체 메시지 */
  message: string;
  author: string;
  action: RebaseAction;
  /** 메시지 고치기일 때 새 메시지 */
  newMessage: string;
}

/** 커밋 정리 계획: base 위로 items 를 다시 쌓는다 */
export interface RebasePlan {
  /** 이 커밋 위로 다시 쌓는다(null 이면 첫 커밋부터 --root) */
  base: string | null;
  /** 화면 순서(위가 최신) */
  items: RebaseItem[];
  /** 원래 순서(위가 최신) */
  original: string[];
  /** 이미 원격에 올린 커밋이 들어 있는지 */
  pushed: boolean;
  /** 확인한 HEAD가 바뀌었으면 실행하지 않는다. */
  expectedHead?: string;
}

export function rebaseItem(sha: string, message: string, author: string): RebaseItem {
  return { sha, message, author, subject: message.split("\n")[0].trim(), action: "pick", newMessage: message };
}

export function makePlan(base: string | null, items: RebaseItem[], pushed = false): RebasePlan {
  return { base, items, original: items.map((i) => i.sha), pushed };
}

/** 실행할 수 없는 계획이면 그 이유 */
export function planProblem(p: RebasePlan): string | null {
  const kept = p.items.filter((i) => i.action !== "drop");
  if (!kept.length) return t("Keep at least one commit.");
  const oldest = kept[kept.length - 1];
  if (oldest.action === "squash" || oldest.action === "fixup") return t("The bottom (oldest) commit has nothing to combine into.");
  if (p.items.some((i) => i.action === "reword" && !i.newMessage.trim())) return t("The new message is empty.");
  return null;
}

/** 원래와 달라진 게 있는지(순서·할 일·메시지) */
export function planChanged(p: RebasePlan): boolean {
  return p.items.some((i, n) => i.sha !== p.original[n]) || p.items.some((i) => i.action !== "pick" && !(i.action === "reword" && i.newMessage === i.message));
}

/** sh 에 넘길 작은따옴표 인용 */
export const shellQuote = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

/** git-rebase-todo 내용(오래된 것부터). 메시지 고치기는 그 커밋을 고른 뒤 새 메시지 파일로 고쳐 쓴다. */
export function rebaseTodo(p: RebasePlan, messageFile: (sha: string) => string): string {
  const out: string[] = [];
  for (const i of [...p.items].reverse()) {
    if (i.action === "reword") {
      out.push(`pick ${i.sha}`);
      if (i.newMessage !== i.message) out.push(`exec git commit --amend --allow-empty -F ${shellQuote(messageFile(i.sha))}`);
    } else out.push(`${i.action} ${i.sha}`);
  }
  return out.join("\n") + "\n";
}
