import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

const read = (path: string) => readFileSync(resolve("..", path), "utf8");
const files = [
  "windows/src/features/repository-assistant/ui/AssistantContextPanel.tsx",
  "windows/src/features/repository-assistant/ui/RepositoryAssistantSheet.tsx",
  "windows/src/features/work-validation/ui/WorkValidationSheet.tsx",
  "windows/src/features/work-validation/ui/VerificationPanel.tsx",
  "windows/src/features/work-validation/ui/TeamHubPanel.tsx",
  "windows/src/features/work-validation/ui/AgentHandoffPanel.tsx",
  "windows/src/shared/lib/team-hub.ts",
  "windows/src/entities/flow/model/store.ts",
];
const required = new Set(files.flatMap(path => [...read(path).matchAll(/\b(?:t|new Error)\("((?:[^"\\]|\\.)*)"/g)].map(match => JSON.parse(`"${match[1]}"`) as string)));
for (const key of ["Verification evidence", "Team overlap evidence", "Agent handoff", "Connected · refreshes every 30 seconds", "Disconnected", "Same-file observation", "Related-file inference", "Observed at {0}", "{0} active participants", "Executed tests: %lld", "Passed tests: %lld", "Failed tests: %lld", "Observed at %@", "%lld active participants"]) required.add(key);
const placeholders = (text: string) => (text.match(/\{\d+\}|%(?:\d+\$)?(?:lld|llu|ld|lu|zu|zd|@|d|u|f|g)/g) ?? []).map(value => value.replace(/%\d+\$/, "%")).sort();
const nativeEntries = (text: string) => [...text.matchAll(/^\s*("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");/gm)].map(match => [JSON.parse(match[1]), JSON.parse(match[2])] as [string, string]);

describe("connected workbench localization", () => {
  it("covers new static and dynamic-error Korean keys on both clients", () => {
    const windows = JSON.parse(read("windows/src/shared/i18n/locales/ko.json")) as Record<string, string>;
    const native = Object.fromEntries(nativeEntries(read("macos/Resources/Localizations/ko.lproj/Localizable.strings")));
    for (const key of required) { expect(windows[key], key).toBeTruthy(); expect(native[key], key).toBeTruthy(); }
  });
  it("preserves placeholder types for translated workbench strings", () => {
    for (const locale of ["ko", "ja", "zh-Hans"]) {
      const windows = JSON.parse(read(`windows/src/shared/i18n/locales/${locale}.json`)) as Record<string, string>;
      const native = Object.fromEntries(nativeEntries(read(`macos/Resources/Localizations/${locale}.lproj/Localizable.strings`)));
      for (const key of required) for (const table of [windows, native]) if (table[key]) expect(placeholders(table[key]), `${locale}: ${key}`).toEqual(placeholders(key));
    }
  });
  it("has no duplicate native keys or obsolete browser-only graph help", () => {
    const obsolete = ["Draws this repository's imports, modules, files that change together or folders with gitch graph, and opens it in your browser.", "Compares the dependencies in your working tree, uncommitted changes included, with where this branch split off from the default branch (gitch graph diff), and opens what changed in your browser."];
    for (const folder of readdirSync(resolve("../macos/Resources/Localizations")).filter(name => name.endsWith(".lproj"))) {
      const entries = nativeEntries(read(`macos/Resources/Localizations/${folder}/Localizable.strings`));
      expect(new Set(entries.map(([key]) => key)).size, folder).toBe(entries.length);
      for (const key of obsolete) expect(entries.some(([candidate]) => candidate === key), folder).toBe(false);
    }
    for (const locale of readdirSync(resolve("src/shared/i18n/locales")).filter(name => name.endsWith(".json"))) {
      const table = JSON.parse(read(`windows/src/shared/i18n/locales/${locale}`)) as Record<string, string>;
      for (const key of obsolete) expect(table[key], locale).toBeUndefined();
    }
  });
});
