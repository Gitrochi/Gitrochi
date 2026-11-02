import assert from "node:assert/strict";
import { spawn, execFile } from "node:child_process";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { endianness, tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { promisify } from "node:util";
import { extractQuestion } from "../extractor.js";
import { nativeClient } from "../native.js";
import { parseFixture } from "./dom.js";

const [fixtureBinary, ledgerBinary] = process.argv.slice(2);
if (!fixtureBinary || !ledgerBinary || !isAbsolute(fixtureBinary) || !isAbsolute(ledgerBinary)) {
  throw new Error("Usage: node tests/native-roundtrip.mjs /absolute/browser_fixture /absolute/gitrochi-ledger");
}
const directory = await mkdtemp(join(tmpdir(), "ledger-browser-roundtrip-"));
const database = join(directory, "ledger.db");
const injectedDatabase = join(directory, "must-not-exist.db");
const environment = { ...process.env };
for (const key of ["GITROCHI_LEDGER_DB", "GITROCHI_LEDGER_SESSION", "GITROCHI_LEDGER"]) delete environment[key];
const child = spawn(fixtureBinary, [database], { env: environment, stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
const listeners = () => {
  const callbacks = new Set();
  return { addListener: (fn) => callbacks.add(fn), removeListener: (fn) => callbacks.delete(fn), emit: (value) => [...callbacks].forEach((fn) => fn(value)) };
};
const replies = [];
let remaining = Buffer.alloc(0);
let stderr = "";
let transportError = null;
let exited = false;
const port = {
  onMessage: listeners(), onDisconnect: listeners(),
  postMessage(message) {
    const body = Buffer.from(JSON.stringify(message), "utf8");
    assert.ok(body.length > 0 && body.length <= 65536);
    const header = Buffer.alloc(4);
    if (endianness() === "LE") header.writeUInt32LE(body.length);
    else header.writeUInt32BE(body.length);
    // Split writes also exercise the host's read_exact framing path.
    child.stdin.write(header.subarray(0, 1));
    child.stdin.write(Buffer.concat([header.subarray(1), body]));
  },
  disconnect() { if (!child.stdin.destroyed) child.stdin.end(); },
};
child.stderr.on("data", (bytes) => { stderr += bytes.toString("utf8"); });
child.stdin.on("error", (error) => { transportError ??= error; });
child.stdout.on("data", (bytes) => {
  try {
    remaining = Buffer.concat([remaining, bytes]);
    while (remaining.length >= 4) {
      const length = endianness() === "LE" ? remaining.readUInt32LE() : remaining.readUInt32BE();
      assert.ok(length > 0 && length <= 1048576, "native stdout must contain framed replies only");
      if (remaining.length < length + 4) break;
      const reply = JSON.parse(remaining.subarray(4, length + 4).toString("utf8"));
      remaining = remaining.subarray(length + 4);
      replies.push(reply);
      port.onMessage.emit(reply);
    }
  } catch (error) { transportError = error; child.kill(); }
});
const exit = new Promise((resolve, reject) => {
  child.once("error", reject);
  child.once("close", (code, signal) => {
    exited = true;
    port.onDisconnect.emit();
    resolve({ code, signal });
  });
});
const native = nativeClient({ runtime: {
  connectNative(name) { assert.equal(name, "com.gitrochi.ledger"); return port; },
} }, () => {}, 5000);
const cli = promisify(execFile);
const readSession = async (id) => {
  const result = await cli(ledgerBinary, ["--db", database, "--json", "session", id], { env: environment, windowsHide: true, timeout: 10000 });
  assert.equal(result.stderr, "");
  return JSON.parse(result.stdout);
};
const expectRejected = async (op, fields) => {
  await assert.rejects(native.request(op, fields), /could not complete/);
  assert.equal(replies.at(-1).ok, false);
};
const waitForExit = async () => {
  let timer;
  try {
    return await Promise.race([exit, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Native fixture did not exit after EOF")), 5000); })]);
  } finally { clearTimeout(timer); }
};

try {
  const html = await readFile(new URL("fixtures/question.html", import.meta.url), "utf8");
  const capture = extractQuestion(parseFixture(html), "https://chatgpt.com/uc/11111111-1111-4111-8111-111111111111");
  assert.ok(capture, "the real extractor must accept the verified fixture");
  const hello = await native.request("hello");
  assert.equal(hello.questionCapture, true);
  assert.equal(hello.composerPredictions, false);
  const empty = await native.request("targets");
  assert.deepEqual(empty.projects, []);
  assert.deepEqual(empty.sessions, []);
  const binding = await native.request("bind", { conversationUrl: capture.conversationUrl, project: "Browser roundtrip fixture" });
  assert.ok(binding.bindingId && binding.sessionId);
  const targets = await native.request("targets");
  assert.ok(targets.projects.some((project) => project.key === "Browser roundtrip fixture"));
  assert.ok(targets.sessions.some((session) => session.id === binding.sessionId));
  const args = { bindingId: binding.bindingId, sourceKey: capture.sourceKey, question: capture.question };
  const first = await native.request("capture", args);
  assert.equal(first.status, "created");
  const duplicate = await native.request("capture", args);
  assert.equal(duplicate.status, "unchanged");
  assert.equal(duplicate.questionId, first.questionId);
  const draft = "  안정 버전 — Stable\n직접 편집한 초안입니다. 🌿  \n";
  const draftArgs = { bindingId: binding.bindingId, sourceKey: capture.sourceKey, text: draft };
  assert.equal((await native.request("draft", draftArgs)).status, "updated");
  assert.equal((await native.request("draft", draftArgs)).status, "unchanged");
  const detail = await readSession(binding.sessionId);
  assert.equal(detail.session.project, "Browser roundtrip fixture");
  assert.equal(detail.questions.length, 1);
  const question = detail.questions[0];
  assert.equal(question.id, first.questionId);
  assert.equal(question.text, capture.question.text);
  assert.deepEqual(question.options, capture.question.options);
  assert.equal(question.browserSourceUrl, capture.conversationUrl);
  assert.equal(question.browserDraft, draft);
  assert.equal(question.state, "open");
  for (const key of ["answer", "answeredAt", "deliveredAt", "suggestedAnswer"]) assert.equal(question[key], undefined);
  assert.equal(detail.waitingMessages, 0);
  assert.deepEqual(detail.events, []);
  assert.equal(detail.session.lastAgentAt, undefined);
  await expectRejected("human", { action: "answer", questionId: first.questionId, answer: "must not send" });
  await expectRejected("capture", { ...args, method: "human" });
  await expectRejected("capture", { ...args, db: injectedDatabase });
  await assert.rejects(access(injectedDatabase));
  assert.deepEqual(await readSession(binding.sessionId), detail, "rejected operations must not alter the stored question");
  await native.request("unbind", { bindingId: binding.bindingId });
  await expectRejected("draft", draftArgs);
  native.closeIfIdle();
  assert.deepEqual(await waitForExit(), { code: 0, signal: null });
  assert.equal(remaining.length, 0, "EOF must leave no partial reply frame");
  assert.equal(stderr, "");
  assert.equal(transportError, null);
  process.stdout.write("PASS browser native roundtrip: real extractor → framed Rust host → isolated Ledger CLI; choices, deduplication, raw Unicode draft, rejection and EOF verified.\n");
} finally {
  native.closeIfIdle();
  if (!exited) {
    child.kill();
    await waitForExit().catch(() => {});
  }
  await rm(directory, { recursive: true, force: true });
}
