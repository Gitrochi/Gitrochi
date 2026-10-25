import { describe, expect, it } from "vitest";
import { buildPatch, canEditLines, diffSides, modeSummary, splitRows, wordRanges } from "@/entities/git/lib/diff";
import { newFileDiff, parseDiff } from "@/entities/git/lib/parsers";

const DIFF = [
  "diff --git a/f.txt b/f.txt",
  "index 1111111..2222222 100644",
  "--- a/f.txt",
  "+++ b/f.txt",
  "@@ -2,3 +2,3 @@",
  " 2",
  "-3",
  "+three",
  " 4",
  "@@ -14,4 +14,4 @@",
  " 14",
  "-15",
  "-16",
  "+fifteen",
  "+sixteen",
  " 17",
  "",
].join("\n");

describe("diff 해석", () => {
  it("덩어리·머리·원문", () => {
    const d = parseDiff(DIFF);
    expect(d.hunks.map((h) => [h.oldStart, h.oldCount, h.newStart, h.newCount])).toEqual([
      [2, 3, 2, 3],
      [14, 4, 14, 4],
    ]);
    expect(d.header[0]).toBe("diff --git a/f.txt b/f.txt");
    expect(canEditLines(d)).toBe(true);
    expect(d.lines.find((l) => l.text === "three")?.hunk).toBe(0);
  });

  it("CRLF 파일: 화면에는 \\r 없이, 패치용 원문에는 그대로", () => {
    const d = parseDiff(DIFF.replace("+three\n", "+three\r\n"));
    const l = d.lines.find((x) => x.kind === "added" && x.text === "three")!;
    expect(l.raw).toBe("three\r");
  });

  it("마지막 줄도 CRLF 원문을 보존한다", () => {
    const d = parseDiff("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\r\n+new\r\n");
    expect(d.lines.at(-1)?.raw).toBe("new\r");
  });
});

describe("줄 단위 패치", () => {
  const d = parseDiff(DIFF);
  it("덩어리 하나 스테이지", () => {
    expect(buildPatch(d, [1], null, false)).toBe(
      ["diff --git a/f.txt b/f.txt", "--- a/f.txt", "+++ b/f.txt", "@@ -14,4 +14,4 @@", " 14", "-15", "-16", "+fifteen", "+sixteen", " 17", ""].join("\n"),
    );
  });
  it("고른 줄만 스테이지: 고르지 않은 - 는 문맥, + 는 뺌", () => {
    const sixteen = d.lines.findIndex((l) => l.text === "sixteen");
    expect(buildPatch(d, [1], new Set([sixteen]), false)).toBe(
      ["diff --git a/f.txt b/f.txt", "--- a/f.txt", "+++ b/f.txt", "@@ -14,4 +14,5 @@", " 14", " 15", " 16", "+sixteen", " 17", ""].join("\n"),
    );
  });
  it("거꾸로(언스테이지·버리기): 고르지 않은 + 는 문맥, - 는 뺌", () => {
    const rm15 = d.lines.findIndex((l) => l.text === "15");
    expect(buildPatch(d, [1], new Set([rm15]), true)).toBe(
      ["diff --git a/f.txt b/f.txt", "--- a/f.txt", "+++ b/f.txt", "@@ -14,5 +14,4 @@", " 14", "-15", " fifteen", " sixteen", " 17", ""].join("\n"),
    );
  });
  it("새 파일은 줄 단위로 못 함", () => {
    expect(canEditLines(parseDiff(DIFF.replace("index 1111111..2222222 100644", "new file mode 100644")))).toBe(false);
  });

  it("앞 덩어리에서 줄 수가 달라져도 뒷 덩어리 역적용은 새 파일의 위치를 쓴다", () => {
    const d = parseDiff("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1,3 @@\n a\n+x\n+y\n@@ -20,3 +22,3 @@\n a\n-old\n+new\n b\n");
    expect(buildPatch(d, [1], null, true)).toContain("@@ -22,3 +22,3 @@");
  });

  it("여러 파일 diff를 첫 파일의 패치로 합치지 않는다", () => {
    expect(canEditLines(parseDiff(DIFF + DIFF.replaceAll("f.txt", "other.txt")))).toBe(false);
  });

  it("줄만 스테이지할 때 실행 권한 변경을 함께 적용하지 않는다", () => {
    const d = parseDiff(DIFF.replace("index 1111111..2222222 100644", "old mode 100644\nnew mode 100755"));
    expect(buildPatch(d, [0], null, false)).not.toMatch(/^(old|new) mode /m);
  });

  it("Git이 따옴표로 감싼 파일명의 줄도 스테이지할 수 있다", () => {
    const d = parseDiff('diff --git "a/a\\tb" "b/a\\tb"\n--- "a/a\\tb"\n+++ "b/a\\tb"\n@@ -1 +1 @@\n-old\n+new\n');
    expect(canEditLines(d)).toBe(true);
  });
});

describe("나란히 보기 · 단어 단위", () => {
  it("지운 줄과 더한 줄을 짝지음", () => {
    const d = parseDiff(DIFF);
    const rows = splitRows(d.lines);
    const pair = rows.find((r) => r.left !== undefined && d.lines[r.left].text === "15");
    expect(pair && d.lines[pair.right!].text).toBe("fifteen");
  });
  it("바뀐 단어 위치", () => {
    expect(wordRanges("let total = price * qty", "let total = price * quantity + fee")).toEqual([[[20, 23]], [[20, 34]]]);
    expect(wordRanges("완전히 다른 줄", "something else entirely")).toEqual([[], []]);
  });
});

describe("파일 종류별", () => {
  it("새 파일: 이전 줄 번호가 없어 한 칸으로, 줄바꿈 없음 표시는 원문 유지", () => {
    const d = parseDiff(["diff --git a/n b/n", "new file mode 100644", "index 0000000..1111111", "--- /dev/null", "+++ b/n", "@@ -0,0 +1,2 @@", "+a", "+b", "\\ No newline at end of file", ""].join("\n"));
    expect(d.info?.newFile).toBe(true);
    expect(diffSides(d.lines)).toEqual({ old: false, new: true });
    expect(d.lines.map((l) => l.kind)).toEqual(["hunk", "added", "added", "meta"]);
    expect(d.lines[3].raw).toBe("\\ No newline at end of file");
  });
  it("권한만 바뀜: 내용 줄 없이 설명만", () => {
    const d = parseDiff("diff --git a/r b/r\nold mode 100644\nnew mode 100755\n");
    expect(d.lines).toEqual([]);
    expect(modeSummary(d.info)).toBe("100644 → 100755 — now executable");
  });
  it("이름 바뀜: 정보만 읽고 줄 목록엔 넣지 않음", () => {
    const d = parseDiff("diff --git a/a b/b\nsimilarity index 95%\nrename from a\nrename to b\nindex 1..2 100644\n--- a/a\n+++ b/b\n@@ -1 +1 @@\n-x\n+y\n");
    expect(d.info).toMatchObject({ renameFrom: "a", renameTo: "b", similarity: 95 });
    expect(d.lines.map((l) => l.kind)).toEqual(["hunk", "removed", "added"]);
    expect(diffSides(d.lines)).toEqual({ old: true, new: true });
  });
  it("추적하지 않는 빈 새 파일", () => {
    const d = newFileDiff("", false);
    expect(d.lines).toEqual([]);
    expect(d.info?.newFile).toBe(true);
  });

  it.each(["\n", "\r\n"])("줄바꿈 하나로 된 새 파일은 한 줄을 표시한다: %j", (text) => {
    expect(newFileDiff(text, false).lines.map((l) => l.kind)).toEqual(["hunk", "added"]);
  });
});
