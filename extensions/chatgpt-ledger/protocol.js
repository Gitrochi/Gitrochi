export const HOST_NAME = "com.gitrochi.ledger";
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Both conversation routes still require the same verified document contract. */
export function canonicalConversation(href) {
  try {
    const url = new URL(href);
    const match = /^\/(uc|c)\/([0-9a-f-]{36})\/?$/i.exec(url.pathname);
    if (url.origin !== "https://chatgpt.com" || url.username || url.password || !match || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(match[2])) return null;
    return `https://chatgpt.com/${match[1].toLowerCase()}/${match[2].toLowerCase()}`;
  } catch { return null; }
}

/** Rebuild the accepted payload so content cannot supply host operations or destinations. */
export function validateQuestion(value) {
  if (!value || typeof value.text !== "string" || !value.text.trim() || value.text.length > 8000) return null;
  if (!Array.isArray(value.options) || value.options.length < 2 || value.options.length > 12) return null;
  const options = [];
  for (const option of value.options) {
    if (!option || typeof option.label !== "string" || !option.label.trim() || option.label.length > 2000) return null;
    if (option.recommended !== undefined && typeof option.recommended !== "boolean") return null;
    options.push({ label: option.label, recommended: option.recommended === true });
  }
  if (new Set(options.map((option) => option.label.trim().normalize("NFC").toLowerCase())).size !== options.length) return null;
  return { text: value.text, options };
}
