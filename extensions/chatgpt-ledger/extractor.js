/** Reads only the verified, complete last assistant question; unsupported layouts return null. */
export function extractQuestion(doc, href) {
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  let url;
  try { url = new URL(href); } catch { return null; }
  const match = /^\/(uc|c)\/([0-9a-f-]{36})\/?$/i.exec(url.pathname);
  if (url.origin !== "https://chatgpt.com" || url.username || url.password || !match || !uuid.test(match[2])) return null;
  const conversationId = match[2].toLowerCase();
  const roots = [...doc.querySelectorAll("section[data-web-mobile-conversation][data-conversation-id]")];
  if (roots.length !== 1 || roots[0].getAttribute("data-conversation-id").toLowerCase() !== conversationId) return null;
  const transcripts = roots[0].querySelectorAll("ol[data-conversation-transcript]");
  if (transcripts.length !== 1) return null;
  const messages = [...transcripts[0].querySelectorAll("li[data-message-role]")];
  const message = messages.at(-1);
  if (!message || message.getAttribute("data-message-role") !== "assistant" || !uuid.test(message.id)) return null;
  if (!message.hasAttribute("data-message-complete") || message.getAttribute("data-message-complete") === "false") return null;
  const busy = [...message.querySelectorAll("[aria-busy]")];
  if (!busy.length || busy.some((node) => node.getAttribute("aria-busy") !== "false")) return null;
  const markdown = message.querySelectorAll("div[data-assistant-markdown-root]");
  if (markdown.length !== 1) return null;
  const contents = markdown[0].querySelectorAll('section[aria-label="DIL content"]');
  if (contents.length !== 1) return null;
  const content = contents[0];
  if (content.querySelector("pre, code, table, form, input, textarea")) return null;
  const lists = [...content.querySelectorAll("ul, ol")];
  if (lists.length !== 1 || lists[0].parentElement !== content) return null;
  const list = lists[0];
  const paragraph = list.previousElementSibling;
  if (!paragraph || paragraph.tagName !== "P") return null;
  const text = paragraph.textContent.trim();
  if (!text || text.length > 8000 || !/[?？]$/.test(text)) return null;
  // Additional prose is allowed, but a second question/list would be ambiguous.
  if ([...content.children].some((node) => node !== paragraph && node !== list && (node.tagName !== "P" || /[?？]\s*$/.test(node.textContent)))) return null;
  const items = [...list.children];
  if (items.length < 2 || items.length > 12 || items.some((item) => item.tagName !== "LI")) return null;
  const labels = items.map((item) => item.textContent.trim());
  if (labels.some((label) => !label || label.length > 2000)) return null;
  if (new Set(labels.map((label) => label.normalize("NFC").toLowerCase())).size !== labels.length) return null;
  const recommendation = /(?:\((?:recommended|추천|권장)\)|\[(?:recommended|추천|권장)\]|（(?:recommended|추천|권장)）|【(?:recommended|추천|권장)】)\s*$/iu;
  return {
    conversationUrl: `https://chatgpt.com/${match[1].toLowerCase()}/${conversationId}`,
    conversationId,
    sourceKey: message.id.toLowerCase(),
    question: { text, options: labels.map((label) => ({ label, recommended: recommendation.test(label) })) },
  };
}
