import { describe, expect, it } from "vitest";
import { parseGraphReview } from "@/entities/gitch";
import { loadLanguage } from "@/shared/i18n";
import { reviewChangeStatusLabel } from "../src/widgets/inspector/lib/commit-impact";

describe("스테이지 변경의 사용자용 상태", () => {
  it("CLI의 실제 상태 코드를 점수나 원문 대신 기존 번역 문구로 표시한다", async () => {
    await loadLanguage("ko");
    try {
      const statuses = ["M", "A", "D", "T", "R100", "R74", "C100", "U", "X"];
      const result = parseGraphReview(JSON.stringify({
        schemaVersion: 1, tool: "gitch graph review", scope: "staged", stamp: "index", snapshot: "tree", headSha: "head", branch: "feature", stale: false,
        changed: statuses.map((status, i) => ({ path: `file${i}.ts`, status, analyzed: true })), direct: [], indirect: [], tests: [],
        coverage: { changed: statuses.length, analyzed: statuses.length, unsupported: 0 }, limitations: [],
      }));
      expect(result?.changed.map((file) => reviewChangeStatusLabel(file.status))).toEqual(["수정됨", "추가됨", "삭제됨", "유형 변경", "이름 변경", "이름 변경", "복사됨", "충돌", "알 수 없음"]);
      expect(reviewChangeStatusLabel("unexpected")).toBe("알 수 없음");
    } finally { await loadLanguage("en"); }
  });
});
