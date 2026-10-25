import { t } from "@/shared/i18n";
import { gitRaw } from "@/shared/platform";
import { type RefSnapshot, sameSnapshot, shortRef, undoSummary, undoTitle } from "../../lib/undo-model";
import { RepoActions } from "./actions";

export type { RefSnapshot, UndoPoint } from "../../lib/undo-model";

/** 되돌리기: run() 이 git 작업 전후의 브랜치·태그·HEAD 를 기록해 두고, 그대로 되돌린다. (맥 버전 RepoStore+Undo) */
export abstract class RepoUndo extends RepoActions {
  protected async refSnapshot(): Promise<RefSnapshot | null> {
    const path = this.path;
    if (!path) return null;
    try {
      const [refs, headRef, head] = await Promise.all([
        gitRaw(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"], path),
        gitRaw(["symbolic-ref", "-q", "HEAD"], path),
        gitRaw(["rev-parse", "-q", "--verify", "HEAD"], path),
      ]);
      if (refs.status !== 0) return null;
      const s: RefSnapshot = { refs: {}, headRef: headRef.status === 0 ? headRef.stdout.trim() : null, head: head.status === 0 ? head.stdout.trim() : null };
      for (const line of refs.stdout.split(/\r?\n/)) {
        const i = line.indexOf(" ");
        if (i > 0) s.refs[line.slice(0, i)] = line.slice(i + 1).trim();
      }
      return s;
    } catch {
      return null;
    }
  }

  protected recordUndo(args: string[], input: string | undefined, before: RefSnapshot, after: RefSnapshot) {
    if (sameSnapshot(before, after)) return;
    this.undoStack = [...this.undoStack, { title: undoTitle(args, input, after), soft: args[0] === "commit", before, after }].slice(-30);
  }

  confirmUndo() {
    const p = this.undoStack[this.undoStack.length - 1];
    if (!p) return;
    this.ask({ title: t("Undo “{0}”?", p.title), message: undoSummary(p), actionTitle: t("Undo"), destructive: false, action: () => this.undo() });
  }

  /** 마지막 작업을 되돌린다. 그 뒤로 저장소가 바뀌었으면(터미널에서 커밋 등) 엉뚱하게 되돌리지 않도록 하지 않는다. */
  async undo() {
    const p = this.undoStack[this.undoStack.length - 1];
    if (!p || !this.path || this.busy != null) return;
    const now = await this.refSnapshot();
    if (!now || !sameSnapshot(now, p.after)) {
      this.undoStack = [];
      this.showError(t("The repository changed since then (a commit, checkout, etc. elsewhere), so “{0}” can't be undone.", p.title));
      return;
    }
    this.busy = t("Undoing…");
    this.emit();
    try {
      // 커밋을 취소하면 그 메시지를 입력 칸에 돌려 놓는다
      if (p.soft && !this.summary && !this.message && p.after.head) {
        const r = await this.g(["log", "-1", "--format=%B", p.after.head]).catch(() => null);
        const lines = (r?.stdout ?? "").trim().split(/\r?\n/);
        this.summary = lines[0] ?? "";
        this.message = lines.slice(1).join("\n").trim();
      }
      // 1) 체크아웃이 바뀌었으면 원래 자리로
      if (p.before.headRef !== p.after.headRef) {
        if (p.before.headRef && p.after.refs[p.before.headRef]) await this.g(["switch", shortRef(p.before.headRef)!]);
        else if (!p.before.headRef && p.before.head) await this.g(["switch", "--detach", p.before.head]);
      }
      // 2) 원래 브랜치(지금 체크아웃한 브랜치)의 끝이 움직였으면 reset
      const oldTip = p.before.headRef ? p.before.refs[p.before.headRef] : p.before.head;
      const newTip = p.before.headRef ? p.after.refs[p.before.headRef] : p.after.head;
      if (oldTip && oldTip !== newTip) await this.g(["reset", p.soft ? "--soft" : "--keep", oldTip]);
      else if (!oldTip && newTip && p.soft && p.before.headRef) await this.g(["update-ref", "-d", p.before.headRef, newTip]);
      // 3) 나머지 브랜치·태그: 생긴 건 지우고, 없어진 건 되살리고, 옮겨진 건 되돌린다
      for (const ref of new Set([...Object.keys(p.before.refs), ...Object.keys(p.after.refs)])) {
        if (ref === p.before.headRef) continue;
        const old = p.before.refs[ref],
          now = p.after.refs[ref];
        if (!old && now) await this.g(["update-ref", "-d", ref, now]);
        else if (old && !now) await this.g(["update-ref", ref, old]);
        else if (old && now && old !== now) await this.g(["update-ref", ref, old, now]);
      }
      this.undoStack = this.undoStack.slice(0, -1);
    } catch (e) {
      this.showError(t("Couldn't undo.\n\n") + String(e instanceof Error ? e.message : e));
    }
    this.busy = null;
    await this.reload();
  }
}
