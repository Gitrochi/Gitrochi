import { afterEach, describe, expect, it } from "vitest";
import { workStateTitle } from "@/entities/hosting";
import { loadLanguage } from "@/shared/i18n";

afterEach(async () => { await loadLanguage("en"); });

describe("work state words", () => {
  it("shows the state, not the Open verb, capitalised for the screen language", async () => {
    await loadLanguage("en");
    expect(["open", "opened", "closed", "merged"].map(workStateTitle)).toEqual(["Open", "Open", "Closed", "Merged"]);
    await loadLanguage("ko");
    expect(["open", "opened", "closed", "merged"].map(workStateTitle)).toEqual(["열림", "열림", "닫힘", "병합됨"]);
    await loadLanguage("de");
    expect(workStateTitle("open")).toBe("Offen"); expect(workStateTitle("merged")).toBe("Zusammengeführt");
    await loadLanguage("ja");
    expect(workStateTitle("closed")).toBe("クローズ");
  });
  it("leaves states it does not know as the server sent them", async () => {
    await loadLanguage("ko");
    expect(workStateTitle("locked")).toBe("locked"); expect(workStateTitle("")).toBe("");
  });
});
