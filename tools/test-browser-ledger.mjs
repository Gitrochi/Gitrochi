// Exercise the extension's real native protocol against an isolated Rust host, without registering Chrome.
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cargo = process.env.GITROCHI_CARGO || "cargo";
const build = spawnSync(cargo, ["build", "--locked", "--manifest-path", path.join(root, "crates/Cargo.toml"), "-p", "gitrochi-ledger", "--example", "browser_fixture", "--message-format=json-render-diagnostics"], {
  cwd: root, windowsHide: true, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], maxBuffer: 16 * 1024 * 1024,
});
if (build.error) throw build.error;
if (build.status !== 0) process.exit(build.status ?? 1);
let fixture;
for (const line of build.stdout.split("\n")) {
  try { const item = JSON.parse(line); if (item.reason === "compiler-artifact" && item.target.name === "browser_fixture" && item.executable) fixture = item.executable; } catch { /* Cargo may print non-JSON status lines. */ }
}
if (!fixture || !path.isAbsolute(fixture)) throw new Error("Cargo did not produce the browser protocol fixture");
const ledger = path.join(root, "windows/src-tauri/generated/gitrochi-ledger.exe");
const run = spawnSync(process.execPath, [path.join(root, "extensions/chatgpt-ledger/tests/native-roundtrip.mjs"), fixture, ledger], { cwd: root, windowsHide: true, stdio: "inherit" });
if (run.error) throw run.error;
process.exit(run.status ?? 1);
