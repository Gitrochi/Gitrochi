import { describe, expect, it } from "vitest";
import { systemLanguage, t } from "@/shared/i18n/i18n";

describe("화면 언어", () => {
  it("번역이 없으면 원문(영어) 그대로, {0} 은 차례로 넘긴 값", () => {
    expect(t("Commit")).toBe("Commit");
    expect(t("Commit {0} files", 3)).toBe("Commit 3 files");
    expect(t("Committed {1} of {0} and stopped.", 5, 2)).toBe("Committed 2 of 5 and stopped.");
  });
  it("시스템 언어: 지원하는 첫 언어, 중국어는 간체·번체 구분, 없으면 영어", () => {
    expect(systemLanguage(["ko-KR", "en-US"])).toBe("ko");
    expect(systemLanguage(["zh-TW"])).toBe("zh-Hant");
    expect(systemLanguage(["zh-CN"])).toBe("zh-Hans");
    expect(systemLanguage(["pt-PT"])).toBe("pt-BR");
    expect(systemLanguage(["ar-EG", "sv-SE"])).toBe("en");
  });
});

describe("번역표 읽기", () => {
  it("한국어·일본어는 번역표에서, 영어는 원문 그대로", async () => {
    const { loadLanguage, t: tr } = await import("@/shared/i18n/i18n");
    await loadLanguage("ko");
    expect(tr("Close other tabs")).toBe("다른 탭 모두 닫기");
    expect(tr("Commit {0} files", 3)).toBe("3개 파일 커밋");
    await loadLanguage("ja");
    expect(tr("Close other tabs")).not.toBe("Close other tabs");
    await loadLanguage("en");
    expect(tr("Close other tabs")).toBe("Close other tabs");
    await loadLanguage(undefined);
    expect(tr("Close other tabs")).toBe("Close other tabs");
  });
});
