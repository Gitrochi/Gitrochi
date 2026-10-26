import { runCore } from "./runtime";

interface Job {
  id: number;
  request: Record<string, unknown>;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

let worker: Worker | undefined;
let active: Job | undefined;
let sequence = 0;
const queue: Job[] = [];

function drain() {
  if (active || !queue.length) return;
  if (!worker) {
    worker = new Worker(new URL("./worker.ts", import.meta.url), { type: "module" });
    worker.onmessage = (event: MessageEvent<{ id: number; value?: unknown; error?: string }>) => {
      if (event.data.id !== active?.id) return;
      const job = active;
      active = undefined;
      if (event.data.error) job.reject(new Error(event.data.error));
      else job.resolve(event.data.value);
      drain();
    };
    worker.onerror = () => {
      worker?.terminate(); worker = undefined;
      const failed = [active, ...queue]; active = undefined; queue.length = 0;
      for (const job of failed) job?.reject(new Error("Shared core worker failed"));
    };
  }
  active = queue.shift()!;
  worker.postMessage({ id: active.id, request: active.request });
}

/** 큰 계산은 직렬 작업 큐로 보내 여러 저장소가 동시에 화면 스레드를 점유하지 않게 한다. */
export function runCoreAsync<T>(request: Record<string, unknown>, signal?: AbortSignal): Promise<T> {
  const aborted = () => new DOMException("Calculation cancelled", "AbortError");
  if (signal?.aborted) return Promise.reject(aborted());
  // Node 단위 검사도 대체 구현 대신 배포하는 바로 그 WASM을 실행한다.
  if (typeof Worker === "undefined") return Promise.resolve().then(() => {
    if (signal?.aborted) throw aborted();
    return runCore<T>(request);
  });
  return new Promise<T>((resolve, reject) => {
    const cleanup = () => signal?.removeEventListener("abort", onAbort);
    const job: Job = { id: ++sequence, request, resolve: (v) => { cleanup(); resolve(v as T); }, reject: (e) => { cleanup(); reject(e); } };
    const onAbort = () => {
      const index = queue.indexOf(job);
      if (index >= 0) queue.splice(index, 1);
      job.reject(aborted());
    };
    signal?.addEventListener("abort", onAbort, { once: true });
    queue.push(job);
    drain();
  });
}
