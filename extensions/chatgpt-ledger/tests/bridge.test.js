import test from "node:test";
import assert from "node:assert/strict";
import { createBridge } from "../bridge.js";
import { nativeClient } from "../native.js";
import { mockChrome, popupSender, contentSender, conversationUrl, sourceKey } from "./chrome.js";

const question = { text: "Which channel?", options: [{ label: "Stable (Recommended)", recommended: true }, { label: "Nightly", recommended: false }] };
async function connected(syncDrafts = true) {
  const mock = mockChrome();
  const bridge = createBridge(mock.api);
  await bridge.handle({ type: "popup.connect", project: "demo", syncDrafts }, popupSender());
  const nonce = mock.tabMessages.find(([, message]) => message.type === "bridge.start")[1].nonce;
  const capture = { type: "content.capture", nonce, conversationUrl, sourceKey, question };
  return { ...mock, bridge, capture };
}

test("explicit popup owns destination and injects only the checked selected document", async () => {
  const { calls, injections, bridge, capture } = await connected();
  assert.equal(bridge.snapshot().connected, true);
  assert.equal(calls.find((m) => m.op === "bind").sessionId, undefined);
  assert.equal(calls.find((m) => m.op === "bind").project, "demo");
  assert.deepEqual(injections[1].target, { tabId: 7, documentIds: ["document-1"] });
  await bridge.handle({ ...capture, bindingId: "evil", project: "other", op: "human", db: "/wrong", question: { ...question, suggestedAnswer: "made up" } }, contentSender());
  assert.deepEqual(calls.at(-1), { version: 1, id: calls.at(-1).id, op: "capture", bindingId: "binding-1", sourceKey, question });
  const raw = "  Stable\nwith detail  ";
  await bridge.handle({ type: "content.draft", nonce: capture.nonce, conversationUrl, sourceKey, text: raw }, contentSender());
  assert.equal(calls.at(-1).text, raw);
  assert.equal(bridge.snapshot().status, "Browser draft synced to Ledger");
  await bridge.stop();
});

test("content cannot bind, retarget or cross extension, origin, frame, tab, document or route", async () => {
  const { bridge, capture, calls } = await connected();
  const before = calls.length;
  for (const sender of [
    { ...contentSender(), id: "foreign" }, { ...contentSender(), origin: "https://example.com" },
    { ...contentSender(), frameId: 1 }, { ...contentSender(), tab: { id: 8 } },
    { ...contentSender(), documentId: "document-2" }, { ...contentSender(), url: conversationUrl.replace("/uc/", "/c/") },
  ]) await assert.rejects(bridge.handle(capture, sender));
  await assert.rejects(bridge.handle({ ...capture, nonce: "wrong" }, contentSender()));
  await assert.rejects(bridge.handle({ ...capture, conversationUrl: "https://example.com" }, contentSender()));
  await assert.rejects(bridge.handle({ type: "popup.connect", project: "evil" }, contentSender()));
  await assert.rejects(bridge.handle({ type: "popup.connect", project: "evil" }, { ...popupSender(), url: "https://chatgpt.com" }));
  assert.equal(calls.length, before);
  await bridge.stop();
});

test("draft opt-in and exact latest source are required; closed result stays closed", async () => {
  const state = await connected(false);
  await state.bridge.handle(state.capture, contentSender());
  const draft = { ...state.capture, type: "content.draft", text: "draft" };
  await assert.rejects(state.bridge.handle(draft, contentSender()));
  await state.bridge.stop();
  const next = await connected();
  await assert.rejects(next.bridge.handle({ ...draft, nonce: next.capture.nonce }, contentSender()));
  await next.bridge.handle(next.capture, contentSender());
  await assert.rejects(next.bridge.handle({ ...draft, nonce: next.capture.nonce, sourceKey: "44444444-4444-4444-8444-444444444444" }, contentSender()));
  next.setBehavior((message, normal) => message.op === "draft" ? { status: "closed" } : normal(message));
  assert.equal((await next.bridge.handle({ ...draft, nonce: next.capture.nonce }, contentSender())).status, "closed");
  assert.equal(next.bridge.snapshot().status, "This question no longer accepts a draft.");
  await next.bridge.stop();
});

test("switching tabs, reload and native disconnect clear ephemeral binding", async () => {
  for (const stopWith of [
    (state) => state.api.tabs.onActivated.emit({ tabId: 9 }),
    (state) => state.api.tabs.onUpdated.emit(7, { status: "loading" }),
    (state) => state.api.tabs.onRemoved.emit(7),
    (state) => state.port.onDisconnect.emit(),
  ]) {
    const state = await connected();
    stopWith(state);
    assert.equal(state.bridge.snapshot().connected, false);
    await assert.rejects(state.bridge.handle(state.capture, contentSender()));
  }
});

test("existing destinations must be active and same project; trusted new projects work", async () => {
  const mock = mockChrome();
  const bridge = createBridge(mock.api);
  await assert.rejects(bridge.handle({ type: "popup.connect", project: "other", sessionId: "active-demo" }, popupSender()));
  await bridge.handle({ type: "popup.connect", project: "New project" }, popupSender());
  assert.equal(mock.calls.find((m) => m.op === "bind").project, "New project");
  await bridge.stop();
});

test("navigation during binding cannot leave a newly attached observer", async () => {
  const mock = mockChrome();
  const bridge = createBridge(mock.api);
  mock.setBehavior((message, normal) => {
    if (message.op === "bind") mock.api.tabs.onUpdated.emit(7, { status: "loading" });
    return normal(message);
  });
  await assert.rejects(bridge.handle({ type: "popup.connect", project: "demo" }, popupSender()));
  assert.equal(bridge.snapshot().connected, false);
  assert.ok(mock.calls.some((message) => message.op === "unbind"));
  assert.equal(mock.tabMessages.filter(([, message]) => message.type === "bridge.start").length, 0);
});

test("native replies require matching version, ID and success contract", async () => {
  const mock = mockChrome();
  mock.setBehavior(() => undefined);
  const native = nativeClient(mock.api, () => {}, 100);
  const pending = native.request("hello");
  const id = mock.calls[0].id;
  mock.port.onMessage.emit({ version: 2, id, ok: true, data: { wrong: true } });
  mock.port.onMessage.emit({ version: 1, id: "wrong", ok: true, data: { wrong: true } });
  mock.port.onMessage.emit({ version: 1, id, ok: true, data: { questionCapture: true } });
  assert.deepEqual(await pending, { questionCapture: true });
  const rejected = native.request("targets");
  mock.port.onMessage.emit({ version: 1, id: mock.calls[1].id, ok: false, error: { message: "private details" } });
  await assert.rejects(rejected, /could not complete/);
});

test("native frame cap measures UTF-8 envelope bytes and EOF rejects pending work", async () => {
  const mock = mockChrome();
  mock.setBehavior(() => undefined);
  let disconnected = 0;
  const native = nativeClient(mock.api, () => { disconnected++; }, 100);
  await assert.rejects(native.request("draft", { text: "한".repeat(22000) }), /too large/);
  assert.equal(mock.calls.length, 0);
  const pending = native.request("capture", { text: "small" });
  mock.port.onDisconnect.emit();
  await assert.rejects(pending, /disconnected/);
  assert.equal(disconnected, 1);
});

test("opening targets and pausing close idle native processes", async () => {
  const mock = mockChrome();
  const bridge = createBridge(mock.api);
  await bridge.handle({ type: "popup.targets" }, popupSender());
  assert.equal(mock.disconnectCount, 1);
  await bridge.handle({ type: "popup.connect", project: "demo" }, popupSender());
  assert.equal(bridge.snapshot().connected, true);
  await bridge.stop();
  assert.equal(mock.disconnectCount, 2);
});

test("answered and changed capture statuses do not claim a new synced question", async () => {
  for (const status of ["answered", "changed"]) {
    const state = await connected();
    state.setBehavior((message, normal) => message.op === "capture" ? { status, questionId: 42 } : normal(message));
    await state.bridge.handle(state.capture, contentSender());
    assert.equal(state.bridge.snapshot().lastResult, status);
    assert.notEqual(state.bridge.snapshot().status, "Question synced to Ledger");
    const before = state.calls.length;
    await assert.rejects(state.bridge.handle({ ...state.capture, type: "content.draft", text: "must not attach to the previous question" }, contentSender()));
    assert.equal(state.calls.length, before);
    await state.bridge.stop();
  }
});
