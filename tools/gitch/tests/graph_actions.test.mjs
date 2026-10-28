import { readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";

// Exercise the exact standalone consumer without evaluating a page or accepting commands.
const source = readFileSync(new URL("../gitch", import.meta.url), "utf8");
const start = source.indexOf("  function validatedGraphActions(value,snapshot) {");
const end = source.indexOf("  function applyGraphEnvelope(value)", start);
const validate = new Function(source.slice(start, end) + ";return validatedGraphActions;")();
const snapshot = { schemaVersion: 1, id: "snapshot", nodeIDs: ["a.ts", "b.ts", "c.ts"], edges: [{ source: "a.ts", target: "b.ts" }] };
const envelope = actions => ({ schemaVersion: 1, snapshotID: "snapshot", actions });
test("standalone actions validate snapshot and directed paths atomically", () => {
  assert.ok(validate(envelope([{ kind: "nodes", nodeIDs: ["a.ts"] }, { kind: "path", nodeIDs: ["a.ts", "b.ts"] }]), snapshot));
  assert.ok(validate(envelope([{ kind: "clear" }]), snapshot));
  for (const value of [
    { ...envelope([]), snapshotID: "old" },
    envelope([{ kind: "path", nodeIDs: ["b.ts", "a.ts"] }]),
    envelope([{ kind: "nodes", nodeIDs: ["a.ts", "missing.ts"] }]),
    envelope([{ kind: "nodes", nodeIDs: ["a.ts", "a.ts"] }]),
    envelope([{ kind: "clear", command: "ignored" }]),
    envelope([{ kind: "shell", command: "ignored" }]),
    { ...envelope([]), command: "ignored" },
    envelope(Array.from({ length: 13 }, () => ({ kind: "clear" }))),
  ]) assert.equal(validate(value, snapshot), null);
});
