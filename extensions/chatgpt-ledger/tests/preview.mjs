import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, extname, sep } from "node:path";

const root = resolve(fileURLToPath(new URL("../", import.meta.url)));
const port = Number(process.env.LEDGER_EXTENSION_PREVIEW_PORT ?? "5199");
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, "http://127.0.0.1");
    const path = resolve(root, `.${decodeURIComponent(url.pathname === "/" ? "/popup.html" : url.pathname)}`);
    if (!path.startsWith(`${root}${sep}`)) throw new Error("Outside preview");
    let content = await readFile(path);
    if (path.endsWith(`${sep}popup.html`)) content = Buffer.from(content.toString().replace('src="popup.js"', 'src="tests/preview.js"'));
    response.writeHead(200, { "content-type": ({ ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" })[extname(path)] ?? "text/plain", "cache-control": "no-store" });
    response.end(content);
  } catch { response.writeHead(404); response.end("Not found"); }
});
server.listen(port, "127.0.0.1", () => process.stdout.write(`Local popup preview: http://127.0.0.1:${port}/popup.html\n`));
