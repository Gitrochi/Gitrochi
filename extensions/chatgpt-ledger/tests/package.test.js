import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { ko, translator } from "../i18n.js";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");
test("manifest requests only opt-in permissions and no automatic page access", async () => {
  const manifest = JSON.parse(await read("manifest.json"));
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.permissions, ["activeTab", "scripting", "nativeMessaging"]);
  for (const key of ["host_permissions", "optional_host_permissions", "content_scripts", "externally_connectable", "web_accessible_resources"]) assert.equal(manifest[key], undefined);
  assert.equal(manifest.background.type, "module");
});

test("popup strings have Korean translations and no inline script", async () => {
  const html = await read("popup.html");
  for (const [, key] of html.matchAll(/data-(?:i18n|placeholder)="([^"]+)"/g)) assert.ok(ko[key], key);
  assert.doesNotMatch(html, /<script[^>]*>\s*\S[^<]*<\/script>/);
  assert.doesNotMatch(html, /\son\w+=/i);
  assert.equal(translator("ko-KR")("Connect"), "연결");
  assert.equal(translator("en-US")("Connect"), "Connect");
  assert.equal(translator("ja")("Connect"), "Connect");
});
