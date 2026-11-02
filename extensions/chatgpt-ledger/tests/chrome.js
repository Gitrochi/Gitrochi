export const conversationUrl = "https://chatgpt.com/uc/11111111-1111-4111-8111-111111111111";
export const sourceKey = "33333333-3333-4333-8333-333333333333";
export const extensionId = "abcdefghijklmnopabcdefghijklmnop";
export const event = () => {
  const listeners = new Set();
  return { addListener: (fn) => listeners.add(fn), removeListener: (fn) => listeners.delete(fn), emit: (...args) => [...listeners].map((fn) => fn(...args)), listeners };
};
export function mockChrome() {
  const calls = [];
  const tabMessages = [];
  const injections = [];
  const port = { onMessage: event(), onDisconnect: event() };
  let disconnectCount = 0;
  port.disconnect = () => { disconnectCount++; port.onDisconnect.emit(); };
  let behavior = (message) => {
    if (message.op === "hello") return { questionCapture: true, composerPredictions: false };
    if (message.op === "targets") return { projects: [{ key: "demo", name: "Demo" }], sessions: [{ id: "active-demo", title: "Active work", project: "demo" }] };
    if (message.op === "bind") return { bindingId: "binding-1", sessionId: message.sessionId ?? "new-browser-session" };
    if (message.op === "capture") return { questionId: 42, status: "created" };
    if (message.op === "draft") return { status: "updated" };
    return {};
  };
  port.postMessage = (message) => {
    calls.push(message);
    Promise.resolve().then(async () => {
      const data = await behavior(message);
      if (data !== undefined) port.onMessage.emit({ version: 1, id: message.id, ok: true, data });
    });
  };
  const api = {
    runtime: {
      id: extensionId, onMessage: event(), getURL: (path) => `chrome-extension://${extensionId}/${path}`,
      connectNative: (name) => { if (name !== "com.gitrochi.ledger") throw new Error("Wrong host"); return port; },
    },
    tabs: {
      onUpdated: event(), onRemoved: event(), onActivated: event(),
      query: async () => [{ id: 7, url: conversationUrl }],
      sendMessage: async (...args) => { tabMessages.push(args); return { ok: true }; },
    },
    scripting: {
      executeScript: async (details) => {
        injections.push(details);
        return [{ frameId: 0, documentId: "document-1", result: details.func ? { href: conversationUrl, conversationId: conversationUrl.split("/").at(-1), supported: true } : undefined }];
      },
    },
  };
  return { api, calls, tabMessages, injections, port, get disconnectCount() { return disconnectCount; }, setBehavior: (fn) => { const previous = behavior; behavior = (message) => fn(message, previous); } };
}
export function popupSender() { return { id: extensionId, url: `chrome-extension://${extensionId}/popup.html` }; }
export function contentSender() { return { id: extensionId, origin: "https://chatgpt.com", url: conversationUrl, frameId: 0, tab: { id: 7 }, documentId: "document-1" }; }
