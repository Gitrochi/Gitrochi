import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { extractQuestion } from "../extractor.js";
import { canonicalConversation, validateQuestion } from "../protocol.js";
import { parseFixture } from "./dom.js";

const html = await readFile(new URL("fixtures/question.html", import.meta.url), "utf8");
const url = "https://chatgpt.com/uc/11111111-1111-4111-8111-111111111111";
const extract = (source = html, href = url) => extractQuestion(parseFixture(source), href);

test("verified fixture preserves full labels, IDs and explicit recommendation", () => {
  assert.deepEqual(extract(), {
    conversationUrl: url, conversationId: url.split("/").at(-1), sourceKey: "33333333-3333-4333-8333-333333333333",
    question: { text: "Which release channel would you prefer?", options: [{ label: "Stable (Recommended)", recommended: true }, { label: "Nightly", recommended: false }] },
  });
  const plain = extract(html.replace(" (Recommended)", ""));
  assert.ok(plain.question.options.every((option) => option.recommended === false));
  assert.equal(extract(html.replace("(Recommended)", "(추천)")).question.options[0].recommended, true);
  assert.equal(extract(html.replace("prefer?", "prefer？")).question.text, "Which release channel would you prefer？");
});

test("only the last complete assistant message can be captured", () => {
  assert.equal(extract(html.replace("data-message-complete", 'data-message-complete="false"')), null);
  assert.equal(extract(html.replace(" data-message-complete", "")), null);
  assert.equal(extract(html.replace('aria-busy="false"', 'aria-busy="true"')), null);
  assert.equal(extract(html.replace("  </ol>", '<li data-message-role="user"><p>Later input</p></li></ol>')), null);
  assert.equal(extract(html.replace("  </ol>", '<li data-message-role="assistant" id="44444444-4444-4444-8444-444444444444"><p>Streaming</p></li></ol>')), null);
});

test("ambiguous, generic, malformed and unsupported DOM fail closed", () => {
  for (const source of [
    html.replace("prefer?", "prefer."),
    html.replace("<ul>", "<ul><li><ul><li>Nested</li></ul></li>"),
    html.replace("Nightly", "Stable (Recommended)"),
    html.replace("<li>Nightly</li>", ""),
    html.replace("<li>Nightly</li>", "<li><code>Nightly</code></li>"),
    html.replace("<ul>", "<p>Another question?</p><ul>"),
    html.replace("<ul>", "<div><ul>").replace("</ul>", "</ul></div>"),
    html.replace("<li>Nightly</li>", Array.from({ length: 12 }, (_, i) => `<li>Option ${i}</li>`).join("")),
    html.replace("data-assistant-markdown-root", "data-unsupported-root"),
    html.replace('data-conversation-id="11111111-1111-4111-8111-111111111111"', 'data-conversation-id="55555555-5555-4555-8555-555555555555"'),
    html + html,
  ]) assert.equal(extract(source), null);
});

test("conversation routes never guess older or foreign layouts", () => {
  assert.equal(canonicalConversation(`${url}/?x=1#bottom`), url);
  const signedInRoute = url.replace("/uc/", "/c/");
  assert.equal(canonicalConversation(signedInRoute), signedInRoute);
  assert.equal(extract(html, signedInRoute).conversationUrl, signedInRoute);
  assert.equal(extract('<div data-message-author-role="assistant"><p>Which?</p><ul><li>A</li><li>B</li></ul></div>', signedInRoute), null);
  for (const href of [url.replace("/uc/", "/conversation/"), url.replace("https:", "http:"), url.replace("chatgpt.com", "chatgpt.com.example.com"), url.replace("https://", "https://user@"), "file:///tmp/chat.html", `${url}/other`]) {
    assert.equal(canonicalConversation(href), null);
    assert.equal(extract(html, href), null);
  }
});

test("payload validation strips routing and never infers a suggested answer", () => {
  const result = validateQuestion({ text: "Choose?", options: [{ label: "A" }, { label: "B", recommended: false }], suggestedAnswer: "A", project: "injected", op: "human" });
  assert.deepEqual(result, { text: "Choose?", options: [{ label: "A", recommended: false }, { label: "B", recommended: false }] });
  assert.equal(validateQuestion({ text: "Choose?", options: [{ label: "A" }, { label: " a " }] }), null);
});
