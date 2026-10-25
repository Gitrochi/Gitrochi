import { describe, expect, it } from "vitest";
import { type ConflictChoice, parseConflict, resolveConflict } from "@/entities/git/lib/conflict";

describe("충돌 해결", () => {
  const text = "1\n<<<<<<< HEAD\ntwo-main\n=======\ntwo-other\n>>>>>>> other\n3\n<<<<<<< HEAD\nf-main\n=======\nf-other\n>>>>>>> other\n4\n";
  it("블록으로 나눔", () => {
    const d = parseConflict(text);
    expect(d.blocks.map((b) => [b.ours, b.theirs, b.oursLabel, b.theirsLabel])).toEqual([
      [["two-main"], ["two-other"], "HEAD", "other"],
      [["f-main"], ["f-other"], "HEAD", "other"],
    ]);
  });
  it("모두 골라야 합침", () => {
    const d = parseConflict(text);
    const c = new Map<number, ConflictChoice>([[0, { kind: "theirs" }]]);
    expect(resolveConflict(d, c)).toBeNull();
    c.set(1, { kind: "oursThenTheirs" });
    expect(resolveConflict(d, c)).toBe("1\ntwo-other\n3\nf-main\nf-other\n4\n");
  });
  it("CRLF·diff3·직접 고치기", () => {
    const d = parseConflict("x\r\n<<<<<<< HEAD\r\nmine\r\n||||||| base\r\norig\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\ny\r\n");
    expect(d.blocks[0].base).toEqual(["orig"]);
    expect(resolveConflict(d, new Map([[0, { kind: "custom", text: "a\nb" }]]))).toBe("x\r\na\r\nb\r\ny\r\n");
  });

  it("사용자 지정 길이의 충돌 표시와 내용 속 짧은 표시를 구분한다", () => {
    const text = "before\n<<<<<<<<<< HEAD\nmine\n=======\n|||||||||| base label\nbase\n==========\ntheirs\n>>>>>>>>>> topic\nafter\n";
    const doc = parseConflict(text);
    expect(doc.blocks).toHaveLength(1);
    expect(doc.blocks[0]).toMatchObject({ oursLabel: "HEAD", theirsLabel: "topic", ours: ["mine", "======="], base: ["base"], theirs: ["theirs"] });
    expect(resolveConflict(doc, new Map([[0, { kind: "ours" }]]))).toBe("before\nmine\n=======\nafter\n");
  });

  it.each([
    "before\n<<<<<<< HEAD\nmine\n",
    "before\n<<<<<<< HEAD\nmine\n||||||| base label\nbase",
    "before\n<<<<<<< HEAD\nmine\n=======\ntheirs\n",
    "<<<<<<<not-a-marker\ntext\n",
  ])("닫히지 않은 표시와 일반 텍스트를 원문 그대로 보존한다: %j", (text) => {
    expect(resolveConflict(parseConflict(text), new Map())).toBe(text);
  });
});
