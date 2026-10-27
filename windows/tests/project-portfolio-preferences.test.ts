import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readProjectPortfolioSelection, saveProjectPortfolioSelection } from "../src/entities/hosting/model/project-portfolio-preferences";

let values: Map<string, string>;
beforeEach(() => {
  values = new Map();
  vi.stubGlobal("localStorage", { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => values.set(key, value) });
});
afterEach(() => vi.unstubAllGlobals());

describe("portfolio selection preferences", () => {
  it("distinguishes missing selection from an explicitly empty selection", () => {
    expect(readProjectPortfolioSelection("account|personal")).toBeNull();
    saveProjectPortfolioSelection("account|personal", []);
    expect(readProjectPortfolioSelection("account|personal")).toEqual([]);
  });
  it("isolates account, scope and repository contexts and stores IDs without task data", () => {
    const context = "account-a|repository|github.com|team/client|/fixture/worktree";
    saveProjectPortfolioSelection(context, ["PROJECT_B", "PROJECT_A", "PROJECT_A"]);
    expect(readProjectPortfolioSelection(context)).toEqual(["PROJECT_A", "PROJECT_B"]);
    expect([...values.values()]).toEqual(['["PROJECT_A","PROJECT_B"]']);
    for (const changed of [context.replace("account-a", "account-b"), context.replace("repository", "personal"), context.replace("team/client", "team/server"), context.replace("/fixture/worktree", "/fixture/other")]) expect(readProjectPortfolioSelection(changed)).toBeNull();
  });
  it("falls back safely for malformed values or unavailable storage", () => {
    saveProjectPortfolioSelection("context", ["A"]);
    const storageKey = [...values.keys()][0];
    for (const value of ["invalid JSON", "null", "{}", '["A",1]', '[""]']) { values.set(storageKey, value); expect(readProjectPortfolioSelection("context")).toBeNull(); }
    vi.stubGlobal("localStorage", { getItem: () => { throw new Error("Unavailable"); }, setItem: () => { throw new Error("Unavailable"); } });
    expect(readProjectPortfolioSelection("context")).toBeNull();
    expect(() => saveProjectPortfolioSelection("context", ["A"])).not.toThrow();
    expect(readProjectPortfolioSelection("")).toBeNull();
  });
});
