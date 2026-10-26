import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, symlink, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync, spawn } from "node:child_process";
import { openRepository, allowedPath, redact, tools } from "./server.mjs";

let temp, repo, home, reader, original;
const script = fileURLToPath(new URL("server.mjs", import.meta.url));
const git = (...args) => execFileSync("git", args, { cwd: repo, encoding: "utf8", env: { ...process.env, HOME: home, XDG_CONFIG_HOME: home, GIT_CONFIG_NOSYSTEM: "1" } });
before(async () => {
  temp = await mkdtemp(path.join(tmpdir(), "gitrochi-reader-"));
  repo = path.join(temp, "repo"); home = path.join(temp, "home");
  await mkdir(repo); await mkdir(home);
  git("init", "-q"); git("config", "user.name", "Example Developer"); git("config", "user.email", "dev@example.com");
  await writeFile(path.join(repo, "source.txt"), "first\nneedle example\n");
  await writeFile(path.join(repo, ".env"), "EXAMPLE_PRIVATE_VALUE=never-include-this\n");
  await writeFile(path.join(repo, "secret.key"), "never-include-key\n");
  await writeFile(path.join(repo, "binary.dat"), Buffer.from([0, 1, 2]));
  git("add", "."); git("commit", "-qm", "Add fixture");
  original = git("rev-parse", "HEAD").trim();
  await writeFile(path.join(repo, "source.txt"), "second\nneedle example\n");
  await writeFile(path.join(repo, ".env"), "EXAMPLE_PRIVATE_VALUE=never-include-this-change\n");
  reader = await openRepository(repo);
});
after(async () => { await rm(temp, { recursive: true, force: true }); });

test("all exposed tools are read-only with strict schemas", () => {
  assert.equal(tools.length, 8);
  assert.ok(tools.every((t) => t.annotations.readOnlyHint && t.inputSchema.additionalProperties === false));
});
test("tracked file reading and exact historical content", async () => {
  const live = await reader.call("read_file", { path: "source.txt" });
  assert.match(live.text, /^second/); assert.equal(live.head, original); assert.equal(live.readOnly, true);
  assert.match((await reader.call("read_file", { path: "source.txt", ref: original })).text, /^first/);
});
test("path boundaries, secrets, metadata and option injection are rejected", async () => {
  for (const p of ["../source.txt", "/etc/passwd", "C:/secret", "C:secret", "file:stream", "a/../source.txt", ".env", "secret.key", ".git/config", "a\\b", "a\0b"]) assert.throws(() => allowedPath(p));
  await assert.rejects(reader.call("git_show", { ref: "--output=outside" }));
  await assert.rejects(reader.call("git_log", { count: 1000 }));
  await assert.rejects(reader.call("git_status", { command: "push" }));
  await assert.rejects(reader.call("shell", { command: "pwd" }));
});
test("whole patches and file lists exclude secret paths", async () => {
  const diff = await reader.call("git_diff");
  assert.match(diff.text, /second/); assert.doesNotMatch(diff.text, /never-include|EXAMPLE_PRIVATE_VALUE|\.env/);
  const show = await reader.call("git_show", { ref: original });
  assert.doesNotMatch(show.text, /never-include|EXAMPLE_PRIVATE_VALUE/);
  assert.doesNotMatch((await reader.call("git_files")).text, /\.env|secret\.key/);
});
test("literal code search is bounded and never reads untracked files", async () => {
  await writeFile(path.join(repo, "untracked.txt"), "needle untracked secret\n");
  const result = await reader.call("search_code", { query: "needle" });
  assert.match(result.text, /source.txt:2:/); assert.doesNotMatch(result.text, /untracked secret/);
  await assert.rejects(reader.call("read_file", { path: "untracked.txt" }));
});
test("binary, oversized and symlink files are rejected", async () => {
  await assert.rejects(reader.call("read_file", { path: "binary.dat" }));
  await writeFile(path.join(repo, "large.txt"), "x".repeat(64001));
  git("add", "large.txt");
  await assert.rejects(reader.call("read_file", { path: "large.txt" }));
  await symlink(path.join(temp, "outside.txt"), path.join(repo, "link.txt"));
  await writeFile(path.join(temp, "outside.txt"), "outside-private\n"); git("add", "link.txt");
  await assert.rejects(reader.call("read_file", { path: "link.txt" }));
});
test("known secret values are redacted", () => {
  assert.doesNotMatch(redact("https://name:secret@example.com/r?private_token=secret api_key=private-value"), /name:secret|=secret|private-value/);
  assert.match(redact("ghp_" + "x".repeat(24)), /redacted/);
  for (const value of ['{"password":"private words"}', '{"api_key":"custom-value"}', String.raw`{"secret":"escaped \" private"}`, "authorization: 'Bearer private words'", "token=private-value"]) {
    assert.doesNotMatch(redact(value), /private|custom-value|escaped/);
  }
});
test("calls preserve HEAD, index and working files", async () => {
  const index = git("write-tree"); const before = await readFile(path.join(repo, "source.txt"));
  await reader.call("git_status"); await reader.call("git_log", { count: 1 }); await reader.call("git_show", { ref: original });
  assert.equal(git("write-tree"), index); assert.equal(git("rev-parse", "HEAD").trim(), original);
  assert.deepEqual(await readFile(path.join(repo, "source.txt")), before);
});
test("stdio initialization, pipelined notification, calls and errors", async () => {
  const child = spawn(process.execPath, [script, "--repo", repo], { stdio: ["pipe", "pipe", "pipe"] });
  const requests = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "fixture", version: "1" } } },
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", id: 2, method: "tools/list" },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "read_file", arguments: { path: "source.txt" } } },
    { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "shell", arguments: {} } },
    { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "git_status", arguments: {} } },
    { jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 5 } },
  ];
  let output = "", errors = "";
  child.stdout.on("data", (b) => { output += b; }); child.stderr.on("data", (b) => { errors += b; });
  child.stdin.end(requests.map((r) => JSON.stringify(r)).join("\n") + "\n");
  const code = await new Promise((resolve, reject) => { child.on("exit", resolve); child.on("error", reject); });
  assert.equal(code, 0, errors);
  const results = output.trim().split("\n").map((s) => JSON.parse(s));
  assert.equal(results.length, 5); assert.equal(results[0].result.protocolVersion, "2025-11-25");
  assert.equal(results[1].result.tools.length, 8); assert.equal(results[2].result.isError, false); assert.equal(results[3].result.isError, true);
  assert.equal(results[4].error.code, -32800);
});
