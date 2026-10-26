import { afterEach, describe, expect, it, vi } from "vitest";
import { gitch, graphLanguage } from "@/entities/gitch";
import { ipc } from "@/shared/api";
import { loadLanguage } from "@/shared/i18n";

afterEach(async () => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  await loadLanguage("en");
});

describe("Offline graph app language", () => {
  it("normalizes Korean, English, and Japanese regional codes with an English fallback", () => {
    for (const [code, expected] of [["ko-KR", "ko"], ["KO_kr", "ko"], ["en-GB", "en"], ["ja-JP", "ja"], ["JA_jp", "ja"], ["de", "en"], ["", "en"]]) {
      expect(graphLanguage(code)).toBe(expected);
    }
  });

  it("passes the app language to generation and watching, with a separate page per language", async () => {
    vi.spyOn(gitch, "bundled", "get").mockReturnValue("/bundled/gitch");
    vi.spyOn(gitch, "bash").mockResolvedValue("/bin/bash");
    vi.spyOn(gitch, "graphUnavailable").mockResolvedValue(null);
    vi.spyOn(gitch, "executable").mockResolvedValue("/bundled/gitch");
    const run = vi.spyOn(ipc, "run").mockImplementation(async (_exe, args) => ({
      status: 0,
      stdout: args.includes("watch") ? '{"url":"http://127.0.0.1:8765/fixture/"}' : "GRAPH_FILE=fixture.html NODES=2 EDGES=1",
      stderr: "",
    }));
    const pages: string[] = [];
    for (const code of ["ko", "en", "ja"]) {
      await loadLanguage(code);
      const start = run.mock.calls.length;
      const page = await gitch.graph("files", "/repo");
      pages.push(page.file);
      const calls = run.mock.calls.slice(start);
      expect(calls).toHaveLength(2);
      for (const call of calls) {
        expect(call[2]?.env?.GITCH_GRAPH_LANG).toBe(code);
        expect(call[1][call[1].indexOf("--out") + 1]).toBe(page.file);
      }
      expect(page.file).toMatch(new RegExp(`-files-${code}-[a-f0-9]+\\.html$`));
    }
    expect(new Set(pages).size).toBe(3);

    await loadLanguage("ja");
    await gitch.commitReviewGraph("/repo");
    await gitch.graphDiff("files", null, "/repo");
    await gitch.graphCheckPage("/repo");
    for (const call of run.mock.calls.slice(-3)) expect(call[2]?.env?.GITCH_GRAPH_LANG).toBe("ja");
    await gitch.run(["version"], "/repo");
    expect(run.mock.lastCall?.[2]?.env).not.toHaveProperty("GITCH_GRAPH_LANG");
  });

  it("uses the resolved system preference when the app follows the system", async () => {
    vi.stubGlobal("navigator", { languages: ["ja-JP", "en-US"] });
    await loadLanguage("system");
    expect(graphLanguage()).toBe("ja");
    await loadLanguage("en");
    expect(graphLanguage()).toBe("en");
    await loadLanguage("de");
    expect(graphLanguage()).toBe("en");
  });
});
