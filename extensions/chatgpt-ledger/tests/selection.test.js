import test from "node:test";
import assert from "node:assert/strict";
import { sessionSelection } from "../selection.js";

const active = [{ id: "selected-session", title: "Work", project: "demo" }];

test("refresh retains closed selection and blocks connect instead of choosing New session", () => {
  const before = sessionSelection(active, "demo", "selected-session", false);
  assert.equal(before.unavailable, false);
  const closed = sessionSelection([], "demo", before.selected, false);
  assert.equal(closed.selected, "selected-session");
  assert.equal(closed.missing, true);
  assert.equal(closed.unavailable, true);
  assert.equal(sessionSelection([], "demo", "", false).unavailable, false);
  assert.equal(sessionSelection(active, "demo", closed.selected, false).unavailable, false);
});

test("newly created connected session is retained through pause until fresh targets arrive", () => {
  const connected = sessionSelection([], "demo", "new-browser-session", true);
  assert.equal(connected.missing, true);
  assert.equal(connected.unavailable, false);
  const paused = sessionSelection([], "demo", connected.selected, false);
  assert.equal(paused.selected, "new-browser-session");
  assert.equal(paused.unavailable, true);
  const refreshed = sessionSelection([{ id: paused.selected, title: "Browser work", project: "demo" }], "demo", paused.selected, false);
  assert.equal(refreshed.unavailable, false);
  assert.equal(refreshed.selected, "new-browser-session");
});

test("a same-ID target in another project cannot validate the retained choice", () => {
  assert.equal(sessionSelection(active, "other", "selected-session", false).unavailable, true);
});
