import { nativeClient } from "./native.js";
import { canonicalConversation, UUID, validateQuestion } from "./protocol.js";

/** Checks the selected document before injecting any observer. Runs in the isolated world. */
export function inspectConversation() {
  const roots = document.querySelectorAll("section[data-web-mobile-conversation][data-conversation-id]");
  return {
    href: location.href,
    conversationId: roots.length === 1 ? roots[0].getAttribute("data-conversation-id") : null,
    supported: roots.length === 1 && roots[0].querySelectorAll("ol[data-conversation-transcript]").length === 1,
  };
}

/** A single ephemeral binding belongs to the trusted popup, never to page-provided routing. */
export function createBridge(chromeApi) {
  let binding = null;
  let generation = 0;
  let connecting = false;
  let opening = false;
  let capabilities = null;
  let status = "Paused";
  let lastResult = null;
  let contentQueue = Promise.resolve();
  const native = nativeClient(chromeApi, () => {
    capabilities = null;
    void stop(false, "Ledger disconnected.");
  });
  const snapshot = () => ({ connected: Boolean(binding), connecting, capabilities, status, lastResult, binding: binding ? {
    tabId: binding.tabId, conversationUrl: binding.conversationUrl, project: binding.project,
    sessionId: binding.sessionId, syncDrafts: binding.syncDrafts,
  } : null });
  const stop = async (notifyHost = true, nextStatus = "Paused") => {
    ++generation;
    const previous = binding;
    binding = null;
    connecting = false;
    status = nextStatus;
    lastResult = null;
    if (!previous) { native.closeIfIdle(); return; }
    const jobs = [chromeApi.tabs.sendMessage(previous.tabId, { type: "bridge.stop" }, { documentId: previous.documentId }).catch(() => {})];
    if (notifyHost) jobs.push(native.request("unbind", { bindingId: previous.bindingId }).catch(() => {}));
    await Promise.all(jobs);
    if (!binding) native.closeIfIdle();
  };
  const hello = async () => {
    const data = await native.request("hello");
    if (data.questionCapture !== true || data.composerPredictions !== false) throw new Error("Update the Ledger browser host.");
    capabilities = { questionCapture: true, composerPredictions: false };
    return capabilities;
  };
  const targets = async () => {
    try {
      await hello();
      const data = await native.request("targets");
      if (!Array.isArray(data.projects) || !Array.isArray(data.sessions)) throw new Error("Update the Ledger browser host.");
      return {
        projects: data.projects.filter((p) => typeof p?.key === "string" && typeof p.name === "string").map(({ key, name }) => ({ key, name })),
        sessions: data.sessions.filter((s) => typeof s?.id === "string" && typeof s.title === "string" && typeof s.project === "string").map(({ id, title, project }) => ({ id, title, project })),
      };
    } finally { if (!binding && !opening) native.closeIfIdle(); }
  };
  const connect = async (message) => {
    if (opening) throw new Error("A connection is already being opened.");
    const project = typeof message.project === "string" ? message.project.trim() : "";
    if (!project || project.length > 256) throw new Error("Enter a project name.");
    const sessionId = message.sessionId;
    if (sessionId !== undefined && (typeof sessionId !== "string" || !sessionId || sessionId.length > 512)) throw new Error("Choose an active session.");
    opening = true;
    await stop();
    connecting = true;
    const epoch = generation;
    let created = null;
    try {
      const available = await targets();
      if (sessionId && !available.sessions.some((s) => s.id === sessionId && s.project === project)) throw new Error("Choose an active session in this project.");
      const [tab] = await chromeApi.tabs.query({ active: true, currentWindow: true });
      const conversationUrl = canonicalConversation(tab?.url);
      if (!Number.isInteger(tab?.id) || !conversationUrl) throw new Error("Open a supported ChatGPT conversation first.");
      const [probe] = await chromeApi.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, func: inspectConversation });
      const expectedId = conversationUrl.split("/").at(-1);
      if (!probe?.documentId || probe.frameId !== 0 || !probe.result?.supported || canonicalConversation(probe.result.href) !== conversationUrl || probe.result.conversationId?.toLowerCase() !== expectedId) throw new Error("This ChatGPT layout is not supported.");
      if (generation !== epoch) throw new Error("The selected conversation changed. Reconnect.");
      created = await native.request("bind", { conversationUrl, project, ...(sessionId ? { sessionId } : {}) });
      if (typeof created.bindingId !== "string" || !created.bindingId || typeof created.sessionId !== "string" || !created.sessionId) throw new Error("Update the Ledger browser host.");
      const injected = await chromeApi.scripting.executeScript({ target: { tabId: tab.id, documentIds: [probe.documentId] }, files: ["content-bundle.js"] });
      if (generation !== epoch || injected.length !== 1 || injected[0].documentId !== probe.documentId) throw new Error("The selected conversation changed. Reconnect.");
      const nonce = crypto.randomUUID();
      binding = { tabId: tab.id, documentId: probe.documentId, conversationUrl, bindingId: created.bindingId, sessionId: created.sessionId, project, nonce, syncDrafts: message.syncDrafts === true, sourceKey: null };
      const result = await chromeApi.tabs.sendMessage(tab.id, { type: "bridge.start", nonce, conversationUrl, syncDrafts: binding.syncDrafts }, { documentId: probe.documentId });
      if (!result?.ok || generation !== epoch || !binding) throw new Error("The selected conversation changed. Reconnect.");
      status = "Watching this conversation";
      return snapshot();
    } catch (error) {
      if (created && binding?.bindingId === created.bindingId) await stop(false);
      if (created?.bindingId) await native.request("unbind", { bindingId: created.bindingId }).catch(() => {});
      status = error.message;
      throw error;
    } finally { connecting = false; opening = false; if (!binding) native.closeIfIdle(); }
  };
  const contentSender = (sender, message) => Boolean(binding && sender.id === chromeApi.runtime.id && sender.origin === "https://chatgpt.com" && sender.frameId === 0 && sender.tab?.id === binding.tabId && sender.documentId === binding.documentId && canonicalConversation(sender.url) === binding.conversationUrl && message.conversationUrl === binding.conversationUrl && message.nonce === binding.nonce);
  const fromContent = async (message, sender) => {
    if (!contentSender(sender, message)) throw new Error("This conversation is not connected.");
    const active = binding;
    if (message.type === "content.stopped") { await stop(); return {}; }
    if (!UUID.test(message.sourceKey ?? "")) throw new Error("Unsupported source message.");
    if (message.type === "content.capture") {
      const question = validateQuestion(message.question);
      if (!question) throw new Error("Unsupported question.");
      active.sourceKey = null;
      const data = await native.request("capture", { bindingId: active.bindingId, sourceKey: message.sourceKey.toLowerCase(), question });
      if (binding !== active) throw new Error("This conversation is not connected.");
      if (!["created", "unchanged", "answered", "changed"].includes(data.status)) throw new Error("Update the Ledger browser host.");
      active.sourceKey = ["created", "unchanged"].includes(data.status) ? message.sourceKey.toLowerCase() : null;
      lastResult = data.status;
      status = data.status === "answered" ? "This question was already answered in Ledger." : data.status === "changed" ? "This question changed. Review it in Ledger." : "Question synced to Ledger";
      return data;
    }
    if (message.type === "content.draft") {
      if (!active.syncDrafts || active.sourceKey !== message.sourceKey.toLowerCase() || typeof message.text !== "string" || !message.text || message.text.length > 65536) throw new Error("No current question accepts this draft.");
      const data = await native.request("draft", { bindingId: active.bindingId, sourceKey: active.sourceKey, text: message.text });
      if (binding !== active) throw new Error("This conversation is not connected.");
      if (!["updated", "unchanged", "closed", "missing"].includes(data.status)) throw new Error("Update the Ledger browser host.");
      lastResult = data.status;
      status = ["updated", "unchanged"].includes(data.status) ? "Browser draft synced to Ledger" : "This question no longer accepts a draft.";
      return data;
    }
    throw new Error("Unsupported request.");
  };
  const handle = async (message, sender) => {
    if (!message || typeof message.type !== "string") throw new Error("Unsupported request.");
    const trustedPopup = sender.id === chromeApi.runtime.id && sender.url === chromeApi.runtime.getURL("popup.html") && !sender.tab;
    if (trustedPopup) {
      if (message.type === "popup.status") return snapshot();
      if (message.type === "popup.targets") return targets();
      if (message.type === "popup.connect") return connect(message);
      if (message.type === "popup.pause") { await stop(); return snapshot(); }
      throw new Error("Unsupported request.");
    }
    if (!["content.capture", "content.draft", "content.stopped"].includes(message.type)) throw new Error("Unsupported request.");
    const task = contentQueue.then(() => fromContent(message, sender));
    contentQueue = task.catch(() => {});
    return task;
  };
  chromeApi.runtime.onMessage.addListener((message, sender, respond) => {
    void handle(message, sender).then((data) => respond({ ok: true, data }), (error) => respond({ ok: false, error: error.message }));
    return true;
  });
  chromeApi.tabs.onUpdated.addListener((tabId, change) => {
    if ((connecting && (change.status === "loading" || change.url)) || (binding?.tabId === tabId && (change.status === "loading" || (change.url && canonicalConversation(change.url) !== binding.conversationUrl)))) void stop();
  });
  chromeApi.tabs.onRemoved.addListener((tabId) => { if (binding?.tabId === tabId) void stop(); });
  chromeApi.tabs.onActivated.addListener(({ tabId }) => { if (connecting || (binding && binding.tabId !== tabId)) void stop(true, "Paused after switching tabs"); });
  return { handle, snapshot, stop };
}
