import { canonicalConversation } from "./protocol.js";
import { translator } from "./i18n.js";
import { sessionSelection } from "./selection.js";

const t = translator(chrome.i18n.getUILanguage());
document.documentElement.lang = chrome.i18n.getUILanguage().startsWith("ko") ? "ko" : "en";
for (const node of document.querySelectorAll("[data-i18n]")) node.textContent = t(node.dataset.i18n);
for (const node of document.querySelectorAll("[data-placeholder]")) node.placeholder = t(node.dataset.placeholder);
const $ = (id) => document.getElementById(id);
$("extension-id").value = chrome.runtime.id;
let sessions = [];
let busy = false;
let connected = false;
let supported = false;
let hostAvailable = false;
let unavailableSession = false;
const request = async (type, fields = {}) => {
  const reply = await chrome.runtime.sendMessage({ type, ...fields });
  if (!reply?.ok) throw new Error(reply?.error ?? "Request rejected. Check the connection and try again.");
  return reply.data;
};
const controls = () => {
  $("connect").disabled = busy || connected || !supported || !hostAvailable || unavailableSession || !$("project").value.trim();
  $("connect").textContent = t(busy ? "Working…" : "Connect");
  $("pause").disabled = busy || !connected;
  $("refresh").disabled = busy;
  for (const id of ["project", "session", "sync-drafts"]) $(id).disabled = busy || connected;
};
const render = (state) => {
  connected = state.connected;
  $("status").textContent = t(state.connecting ? "Connecting…" : state.status);
  $("destination").textContent = state.binding ? `${state.binding.project} · ${t("Connected session")}: ${state.binding.sessionId}` : "";
  $("capabilities").textContent = state.capabilities?.questionCapture ? t("Questions: supported on the verified ChatGPT layout.") : "";
  if (state.binding) {
    $("project").value = state.binding.project;
    renderSessions(state.binding.sessionId);
    $("sync-drafts").checked = state.binding.syncDrafts;
  } else renderSessions($("session").value);
  controls();
};
const showError = (key) => { $("error").hidden = !key; $("error").textContent = key ? t(key) : ""; };
const renderSessions = (selected = "") => {
  const selection = sessionSelection(sessions, $("project").value, selected, connected);
  unavailableSession = selection.unavailable;
  $("session-warning").hidden = !unavailableSession;
  $("session").replaceChildren(new Option(t("New session"), ""));
  for (const session of selection.available) $("session").add(new Option(session.title, session.id));
  if (selection.missing) {
    const placeholder = new Option(t(connected ? "Connected session" : "Session unavailable"), selected);
    placeholder.disabled = unavailableSession;
    $("session").add(placeholder);
  }
  $("session").value = selected;
};
const refresh = async () => {
  busy = true;
  controls();
  showError(null);
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    supported = Boolean(canonicalConversation(tab?.url));
    const targets = await request("popup.targets");
    hostAvailable = true;
    sessions = targets.sessions;
    $("projects").replaceChildren(...targets.projects.map((project) => new Option(project.name, project.key)));
    renderSessions($("session").value);
    render(await request("popup.status"));
    if (!supported) showError("Open a supported ChatGPT conversation first.");
  } catch {
    hostAvailable = false;
    showError("Ledger browser host is unavailable. Open setup below, then refresh.");
    $("setup").open = true;
  } finally { busy = false; controls(); }
};
$("project").addEventListener("input", () => { renderSessions(); controls(); });
$("session").addEventListener("change", () => { renderSessions($("session").value); controls(); });
$("refresh").addEventListener("click", () => void refresh());
$("connection-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (busy || connected || !supported || !hostAvailable || unavailableSession) return;
  busy = true;
  controls();
  showError(null);
  try {
    render(await request("popup.connect", { project: $("project").value, ...($("session").value ? { sessionId: $("session").value } : {}), syncDrafts: $("sync-drafts").checked }));
  } catch (error) { showError(error.message); }
  finally { busy = false; controls(); }
});
$("pause").addEventListener("click", async () => {
  busy = true;
  controls();
  try { render(await request("popup.pause")); await refresh(); }
  catch (error) { showError(error.message); }
  finally { busy = false; controls(); }
});
setInterval(() => { if (!busy) void request("popup.status").then(render).catch(() => {}); }, 800);
void refresh();
