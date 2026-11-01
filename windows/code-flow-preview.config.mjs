import { defineConfig, mergeConfig } from "vite";
import base from "./vite.config.ts";
import { spawn } from "node:child_process";
import { readdir } from "node:fs/promises";
import { resolve } from "node:path";
const engine = resolve(process.cwd(), "../tools/gitch-flow/target/debug/gitch-flow");
const repo = resolve(process.env.GITROCHI_FLOW_PREVIEW_REPO ?? "../.build/flow-code-preview/shop-web");
export default mergeConfig(base, defineConfig({
 define: { "import.meta.env.VITE_GITROCHI_FLOW_PREVIEW_REPO": JSON.stringify(repo) },
 server: { host: "127.0.0.1", port: 1423, strictPort: true },
 plugins: [{ name: "code-flow-verification", configureServer(server) {
  server.middlewares.use("/__code_flow", (request, response) => {
   if (request.method !== "POST") { response.statusCode = 405; response.end(); return; }
   let text = "";
   request.on("data", (chunk) => { text += chunk; if (text.length > 16 * 1024 * 1024) request.destroy(); });
   request.on("end", async () => {
    try {
     const { operation, payload = {} } = JSON.parse(text);
     if (operation === "files") { response.setHeader("Content-Type", "application/json"); response.end(JSON.stringify({ status: 0, stdout: JSON.stringify(await readdir(resolve(repo, ".gitch/flows")).catch(() => [])), stderr: "" })); return; }
     let args;
     if (["inspect", "render", "source"].includes(operation)) args = ["design", operation, "--json"];
     else if (["blocks", "list", "validate"].includes(operation)) args = [operation, "--json"];
     else if (operation === "plan" && /^[A-Za-z_][A-Za-z0-9_.-]*$/.test(payload.flow)) args = ["plan", payload.flow, "--json"];
     else throw new Error("Only local source authoring and read-only metadata are allowed.");
     const child = spawn(engine, args, { cwd: repo, env: { ...process.env, GITCH_FLOW_LANG: "en", GITSW_ACTOR: "gitrochi-app" }, stdio: ["pipe", "pipe", "pipe"] });
     let stdout = "", stderr = "";
     child.stdout.on("data", (chunk) => { stdout += chunk; }); child.stderr.on("data", (chunk) => { stderr += chunk; });
     const timer = setTimeout(() => child.kill(), 15000);
     child.on("error", (error) => { clearTimeout(timer); response.statusCode = 500; response.end(error.message); });
     child.on("close", (status) => { clearTimeout(timer); response.setHeader("Content-Type", "application/json"); response.end(JSON.stringify({ status, stdout, stderr })); });
     child.stdin.end(["inspect", "render", "source"].includes(operation) ? JSON.stringify(payload) : "");
    } catch (error) { response.statusCode = 400; response.end(String(error)); }
   });
  });
 } }],
}));
