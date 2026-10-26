import { runCore } from "./runtime";

globalThis.onmessage = (event: MessageEvent<{ id: number; request: Record<string, unknown> }>) => {
  const { id, request } = event.data;
  try { globalThis.postMessage({ id, value: runCore(request) }); }
  catch (e) { globalThis.postMessage({ id, error: e instanceof Error ? e.message : String(e) }); }
};
