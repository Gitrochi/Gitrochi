import { HOST_NAME } from "./protocol.js";

/** Owns framed Chrome native messaging without exposing host operations to page scripts. */
export function nativeClient(chromeApi, onDisconnect, timeoutMs = 10000) {
  let port = null;
  let serial = 0;
  const pending = new Map();
  let detach = () => {};
  const close = () => {
    const previous = port;
    port = null;
    detach();
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error("Ledger disconnected."));
    }
    pending.clear();
    previous?.disconnect();
  };
  const disconnect = () => {
    void chromeApi.runtime.lastError;
    close();
    onDisconnect();
  };
  return {
    request(op, fields = {}) {
      const id = `extension-${++serial}`;
      const message = { version: 1, id, op, ...fields };
      if (new TextEncoder().encode(JSON.stringify(message)).length > 65536) return Promise.reject(new Error("This content is too large to sync."));
      if (!port) {
        port = chromeApi.runtime.connectNative(HOST_NAME);
        port.onDisconnect.addListener(disconnect);
        const receive = (reply) => {
          if (!reply || reply.version !== 1 || typeof reply.id !== "string" || typeof reply.ok !== "boolean") return;
          const entry = pending.get(reply.id);
          if (!entry) return;
          pending.delete(reply.id);
          clearTimeout(entry.timer);
          if (reply.ok && reply.data && typeof reply.data === "object") entry.resolve(reply.data);
          else entry.reject(new Error("Ledger could not complete the request."));
        };
        port.onMessage.addListener(receive);
        const connectedPort = port;
        detach = () => {
          connectedPort.onDisconnect.removeListener(disconnect);
          connectedPort.onMessage.removeListener(receive);
        };
      }
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error("Ledger did not respond. Pause and reconnect."));
          disconnect();
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
        try { port.postMessage(message); }
        catch { clearTimeout(timer); pending.delete(id); reject(new Error("Ledger disconnected.")); disconnect(); }
      });
    },
    closeIfIdle() { if (!pending.size) close(); },
  };
}
