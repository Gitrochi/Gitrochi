import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import { parseFixture } from "./dom.js";
import { event, extensionId, conversationUrl } from "./chrome.js";

const bundle = await readFile(new URL("../content-bundle.js", import.meta.url), "utf8");
const fixture = await readFile(new URL("fixtures/question.html", import.meta.url), "utf8");
const settle = async () => { for (let i = 0; i < 6; i++) await Promise.resolve(); };
function harness(syncDrafts = true, captureStatus = "created") {
  const document = parseFixture(fixture);
  const listeners = new Map();
  const timers = new Map();
  const frames = new Map();
  const intervals = new Map();
  const mutations = [];
  let serial = 0;
  const sent = [];
  const runtimeMessages = event();
  const addEventListener = (type, fn) => { if (!listeners.has(type)) listeners.set(type, new Set()); listeners.get(type).add(fn); };
  const removeEventListener = (type, fn) => listeners.get(type)?.delete(fn);
  Object.assign(document, { addEventListener, removeEventListener });
  const location = { href: conversationUrl };
  const context = {
    document, location, URL,
    window: { addEventListener, removeEventListener },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; mutations.push(this); }
      observe() { this.active = true; }
      disconnect() { this.active = false; }
    },
    setTimeout: (fn) => { const id = ++serial; timers.set(id, fn); return id; },
    clearTimeout: (id) => timers.delete(id),
    setInterval: (fn) => { const id = ++serial; intervals.set(id, fn); return id; },
    clearInterval: (id) => intervals.delete(id),
    requestAnimationFrame: (fn) => { const id = ++serial; frames.set(id, fn); return id; },
    cancelAnimationFrame: (id) => frames.delete(id),
    chrome: { runtime: { id: extensionId, getURL: (path) => `chrome-extension://${extensionId}/${path}`, onMessage: runtimeMessages,
      sendMessage: async (message) => { sent.push(message); return { ok: true, data: { status: captureStatus } }; },
    } },
  };
  vm.runInNewContext(bundle, context);
  const dispatch = (type, value = {}) => { for (const fn of listeners.get(type) ?? []) fn(value); };
  const start = () => runtimeMessages.emit({ type: "bridge.start", nonce: "nonce", conversationUrl, syncDrafts }, { id: extensionId, url: `chrome-extension://${extensionId}/worker.js` }, () => {});
  const flush = async () => { for (const [id, fn] of [...timers]) { timers.delete(id); fn(); } await settle(); };
  const raf = async () => { for (const [id, fn] of [...frames]) { frames.delete(id); fn(); } await settle(); };
  const mutate = () => mutations.filter((observer) => observer.active).forEach((observer) => observer.callback());
  const composer = () => document.querySelector("textarea#mobile-composer-prompt[data-mobile-composer-prompt]");
  const key = (extra = {}) => dispatch("keydown", { key: "Tab", isTrusted: true, target: composer(), ...extra });
  start();
  return { document, sent, location, dispatch, key, flush, raf, mutate, composer, intervals, runtimeMessages, mutations };
}

test("observer deduplicates complete questions and clears on route change", async () => {
  const state = harness();
  await state.flush();
  assert.equal(state.sent.filter((message) => message.type === "content.capture").length, 1);
  state.mutate();
  state.mutate();
  await state.flush();
  assert.equal(state.sent.filter((message) => message.type === "content.capture").length, 1);
  state.location.href = conversationUrl.replace("11111111-1111-4111-8111-111111111111", "55555555-5555-4555-8555-555555555555");
  for (const fn of state.intervals.values()) fn();
  await settle();
  assert.equal(state.sent.at(-1).type, "content.stopped");
  assert.equal(state.intervals.size, 0);
  assert.ok(state.mutations.every((observer) => !observer.active));
});

test("only trusted plain Tab from the exact empty known textarea captures accepted text", async () => {
  const state = harness();
  await state.flush();
  const field = state.composer();
  state.key();
  field.value = "  Stable\nadditional context  ";
  await state.raf();
  assert.equal(state.sent.at(-1).type, "content.draft");
  assert.equal(state.sent.at(-1).text, field.value);
  const drafts = state.sent.filter((message) => message.type === "content.draft").length;
  for (const extra of [{ isTrusted: false }, { shiftKey: true }, { ctrlKey: true }, { altKey: true }, { metaKey: true }, { isComposing: true }, { target: {} }, { key: "a" }]) {
    field.value = "";
    state.key(extra);
    field.value = "should not sync";
    await state.raf();
  }
  field.value = " ";
  state.key();
  field.value = "typed answer";
  await state.raf();
  state.dispatch("input", { target: field, isTrusted: true });
  assert.equal(state.sent.filter((message) => message.type === "content.draft").length, drafts);
});

test("Tab does not send until actual text appears; another key or pointer cancels it", async () => {
  const state = harness();
  await state.flush();
  state.key();
  await state.raf();
  assert.equal(state.sent.some((message) => message.type === "content.draft"), false);
  for (const interrupt of [() => state.key({ key: "a" }), () => state.dispatch("pointerdown", { isTrusted: true })]) {
    state.composer().value = "";
    state.key();
    state.composer().value = "accepted too late";
    interrupt();
    await state.raf();
  }
  assert.equal(state.sent.some((message) => message.type === "content.draft"), false);
});

test("normal typing, opt-out, unknown composer and new message never target an older question", async () => {
  const off = harness(false);
  await off.flush();
  off.key(); off.composer().value = "not opted in"; await off.raf();
  assert.equal(off.sent.some((message) => message.type === "content.draft"), false);
  const state = harness();
  await state.flush();
  state.composer().setAttribute("id", "unsupported-composer");
  state.key(); await state.raf();
  assert.equal(state.sent.some((message) => message.type === "content.draft"), false);
  state.document.querySelector("textarea").setAttribute("id", "mobile-composer-prompt");
  state.key();
  state.composer().value = "do not target old assistant";
  const transcript = state.document.querySelector("ol[data-conversation-transcript]");
  transcript.nodes.push(...parseFixture('<li data-message-role="user">New message</li>').children);
  await state.raf();
  state.mutate(); await state.flush();
  assert.equal(state.sent.some((message) => message.type === "content.draft"), false);
});

test("worker stop removes listeners and pending Tab capture", async () => {
  const state = harness();
  await state.flush();
  state.key();
  state.composer().value = "pending";
  state.runtimeMessages.emit({ type: "bridge.stop" }, { id: extensionId }, () => {});
  await state.raf();
  state.key(); await state.raf();
  assert.equal(state.sent.some((message) => message.type === "content.draft"), false);
  assert.equal(state.intervals.size, 0);
});

test("changed or answered captures never enable accepted Tab draft capture", async () => {
  for (const status of ["changed", "answered"]) {
    const state = harness(true, status);
    await state.flush();
    state.key();
    state.composer().value = "answer to a different question";
    await state.raf();
    assert.equal(state.sent.some((message) => message.type === "content.draft"), false);
  }
});
