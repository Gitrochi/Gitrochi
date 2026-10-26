import { describe, expect, it } from "vitest";
import { makePlan, planChanged, planProblem, rebaseItem, rebaseTodo, shellQuote } from "@/entities/git/lib/rebase";
import { undoTitle } from "@/entities/repo/lib/undo-model";

const plan = () => makePlan("base", [rebaseItem("e", "add e", "d"), rebaseItem("d", "add d", "d"), rebaseItem("c", "add c", "d"), rebaseItem("b", "add b\n\n본문", "d")]);

describe("커밋 정리 계획", () => {
  it("처음엔 바뀐 것 없음", () => {
    const p = plan();
    expect(planChanged(p)).toBe(false);
    expect(planProblem(p)).toBeNull();
    expect(p.items[3].subject).toBe("add b");
  });
  it("할 일 목록: 오래된 것부터, 메시지 고치기는 pick 뒤 amend", () => {
    const p = plan();
    p.items[3] = { ...p.items[3], action: "reword", newMessage: "b 고침" };
    p.items[2] = { ...p.items[2], action: "squash" };
    p.items[1] = { ...p.items[1], action: "drop" };
    p.items.push(p.items.shift()!);
    expect(planChanged(p)).toBe(true);
    expect(rebaseTodo(p, (sha) => `/g/msg-${sha}`)).toBe(
      ["pick e", "pick b", "exec git commit --amend --allow-empty -F '/g/msg-b'", "squash c", "drop d", ""].join("\n"),
    );
  });
  it("가장 오래된 커밋은 합칠 수 없고, 모두 빼거나 빈 메시지는 안 됨", () => {
    const p = plan();
    p.items[3] = { ...p.items[3], action: "fixup" };
    expect(planProblem(p)).toContain("nothing to combine");
    p.items = p.items.map((i) => ({ ...i, action: "drop" }));
    expect(planProblem(p)).toContain("at least one");
    const q = plan();
    q.items[0] = { ...q.items[0], action: "reword", newMessage: "  " };
    expect(planProblem(q)).toContain("empty");
  });
  it("메시지를 그대로 둔 '메시지 고치기'는 바뀐 것이 아님", () => {
    const p = plan();
    p.items[0] = { ...p.items[0], action: "reword" };
    expect(planChanged(p)).toBe(false);
    expect(rebaseTodo(p, () => "x")).not.toContain("exec");
  });
  it("작은따옴표 인용과 되돌리기 제목", () => {
    expect(shellQuote("C:/a b/it's")).toBe(`'C:/a b/it'\\''s'`);
    const snap = { heads: {}, tags: {}, head: "x", headRef: "refs/heads/main" };
    expect(undoTitle(["-c", "sequence.editor=cp 'x'", "rebase", "-i", "--autostash", "abc"], undefined, snap as never)).toBe("Clean up commits");
  });
});
