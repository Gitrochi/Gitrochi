// Built into an isolated-world script; no page messaging or page-provided destinations.
const runtimeKey = "__gitrochiLedgerBrowserBridge";
globalThis[runtimeKey]?.stop();
let config = null;
let observer = null;
let debounce = null;
let routeTimer = null;
let frame = null;
let pendingTab = null;
let lastFingerprint = "";
let pendingFingerprint = "";
let lastSourceKey = null;
const send = (message) => chrome.runtime.sendMessage(message).catch(() => ({ ok: false }));
const stop = () => {
  config = null;
  observer?.disconnect();
  observer = null;
  clearTimeout(debounce);
  clearInterval(routeTimer);
  cancelAnimationFrame(frame);
  pendingTab = null;
  document.removeEventListener("keydown", keydown, true);
  document.removeEventListener("pointerdown", cancelPending, true);
  window.removeEventListener("pagehide", routeChanged);
  window.removeEventListener("popstate", checkRoute);
  window.removeEventListener("hashchange", checkRoute);
  lastFingerprint = "";
  pendingFingerprint = "";
  lastSourceKey = null;
};
const routeChanged = () => {
  const previous = config;
  stop();
  if (previous) void send({ type: "content.stopped", nonce: previous.nonce, conversationUrl: previous.conversationUrl });
};
const checkRoute = () => {
  if (config && canonicalConversation(location.href) !== config.conversationUrl) routeChanged();
};
const collect = async () => {
  checkRoute();
  if (!config) return;
  const capture = extractQuestion(document, location.href);
  if (!capture || capture.conversationUrl !== config.conversationUrl) {
    lastSourceKey = null;
    lastFingerprint = "";
    cancelPending();
    return;
  }
  const fingerprint = JSON.stringify([capture.sourceKey, capture.question]);
  if (fingerprint === lastFingerprint || fingerprint === pendingFingerprint) return;
  const active = config;
  lastSourceKey = null;
  pendingFingerprint = fingerprint;
  const result = await send({ type: "content.capture", nonce: active.nonce, ...capture });
  if (config !== active) return;
  pendingFingerprint = "";
  if (result?.ok && ["created", "unchanged", "answered", "changed"].includes(result.data?.status)) {
    lastFingerprint = fingerprint;
    lastSourceKey = ["created", "unchanged"].includes(result.data.status) ? capture.sourceKey : null;
  }
};
const schedule = () => {
  clearTimeout(debounce);
  debounce = setTimeout(() => void collect(), 180);
};
const cancelPending = () => {
  pendingTab = null;
  cancelAnimationFrame(frame);
};
const knownComposer = () => {
  const fields = document.querySelectorAll("textarea#mobile-composer-prompt[data-mobile-composer-prompt]");
  return fields.length === 1 ? fields[0] : null;
};
const keydown = (event) => {
  cancelPending();
  if (!config?.syncDrafts || !event.isTrusted || event.key !== "Tab" || event.shiftKey || event.altKey || event.ctrlKey || event.metaKey || event.isComposing) return;
  const field = knownComposer();
  if (!field || event.target !== field || field.disabled || field.readOnly || field.value !== "" || !lastSourceKey) return;
  const active = config;
  const sourceKey = lastSourceKey;
  const token = {};
  pendingTab = token;
  frame = requestAnimationFrame(() => {
    if (pendingTab !== token || config !== active) return;
    pendingTab = null;
    checkRoute();
    const capture = extractQuestion(document, location.href);
    if (!config || knownComposer() !== field || !field.isConnected || !capture || capture.sourceKey !== sourceKey || !field.value || field.value.length > 65536) return;
    void send({ type: "content.draft", nonce: active.nonce, conversationUrl: active.conversationUrl, sourceKey, text: field.value });
  });
};
const onMessage = (message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.tab || (sender.url && !sender.url.startsWith(chrome.runtime.getURL("")))) return;
  if (message?.type === "bridge.stop") { stop(); respond({ ok: true }); return; }
  if (message?.type !== "bridge.start" || canonicalConversation(location.href) !== message.conversationUrl || typeof message.nonce !== "string") return;
  stop();
  const root = document.querySelector("section[data-web-mobile-conversation][data-conversation-id]");
  if (!root || !root.querySelector("ol[data-conversation-transcript]")) { respond({ ok: false }); return; }
  config = { nonce: message.nonce, conversationUrl: message.conversationUrl, syncDrafts: message.syncDrafts === true };
  observer = new MutationObserver(schedule);
  observer.observe(root, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["data-message-complete", "aria-busy", "data-message-role"] });
  document.addEventListener("keydown", keydown, true);
  document.addEventListener("pointerdown", cancelPending, true);
  window.addEventListener("pagehide", routeChanged);
  window.addEventListener("popstate", checkRoute);
  window.addEventListener("hashchange", checkRoute);
  routeTimer = setInterval(checkRoute, 400);
  schedule();
  respond({ ok: true });
};
chrome.runtime.onMessage.addListener(onMessage);
globalThis[runtimeKey] = { stop: () => { stop(); chrome.runtime.onMessage.removeListener(onMessage); } };
