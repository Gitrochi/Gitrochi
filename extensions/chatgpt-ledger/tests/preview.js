// Local-only popup preview. This never connects to Chrome or the native host.
const params = new URLSearchParams(location.search);
const language = params.get("lang") === "ko" ? "ko" : "en";
if (params.get("theme") === "dark") {
  const root = document.documentElement;
  root.style.colorScheme = "dark";
  for (const [key, value] of Object.entries({ surface: "#1f1f21", text: "#f3f3f4", muted: "#b2b2b8", line: "#444448", control: "#2c2c2f" })) root.style.setProperty(`--${key}`, value);
}
const url = "https://chatgpt.com/uc/11111111-1111-4111-8111-111111111111";
let connected = params.get("state") === "connected";
let project = "demo";
let syncDrafts = false;
const state = () => ({ connected, capabilities: { questionCapture: true, composerPredictions: false }, status: connected ? "Watching this conversation" : "Paused", binding: connected ? { project, sessionId: "browser-demo", syncDrafts } : null });
globalThis.chrome = {
  i18n: { getUILanguage: () => language },
  tabs: { query: async () => [{ id: 7, url }] },
  runtime: {
    id: "abcdefghijklmnopabcdefghijklmnop",
    sendMessage: async (message) => {
      if (message.type === "popup.targets") return { ok: true, data: { projects: [{ key: "demo", name: "Demo" }], sessions: [{ id: "browser-demo", title: "Release channel review", project: "demo" }] } };
      if (message.type === "popup.connect") { connected = true; project = message.project; syncDrafts = message.syncDrafts; }
      if (message.type === "popup.pause") connected = false;
      return { ok: true, data: state() };
    },
  },
};
await import("../popup.js");
