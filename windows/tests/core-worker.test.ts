import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

class ControlledWorker {
  static instances: ControlledWorker[] = [];
  onmessage?: (event: { data: { id: number; value?: unknown; error?: string } }) => void;
  onerror?: () => void;
  posted: Array<{ id: number; request: Record<string, unknown> }> = [];
  terminated = false;
  constructor() { ControlledWorker.instances.push(this); }
  postMessage(message: { id: number; request: Record<string, unknown> }) { this.posted.push(message); }
  terminate() { this.terminated = true; }
  finish(value: unknown) { this.onmessage?.({ data: { id: this.posted.at(-1)!.id, value } }); }
}

beforeEach(() => { vi.resetModules(); ControlledWorker.instances = []; vi.stubGlobal("Worker", ControlledWorker); });
afterEach(() => vi.unstubAllGlobals());

describe("공통 계산 작업 큐", () => {
  it("순서대로 하나씩 실행하며 요청마다 올바른 응답을 준다", async () => {
    const { runCoreAsync } = await import("@/shared/core");
    const first = runCoreAsync({ op: "bodyPreview", text: "one" });
    const second = runCoreAsync({ op: "bodyPreview", text: "two" });
    const worker = ControlledWorker.instances[0];
    expect(worker.posted).toHaveLength(1);
    worker.finish("one");
    expect(worker.posted).toHaveLength(2);
    worker.finish("two");
    expect(await Promise.all([first, second])).toEqual(["one", "two"]);
  });

  it("취소한 대기 계산은 worker로 보내지 않는다", async () => {
    const { runCoreAsync } = await import("@/shared/core");
    const first = runCoreAsync({ op: "bodyPreview", text: "one" });
    const signal = new AbortController();
    const cancelled = runCoreAsync({ op: "bodyPreview", text: "stale" }, signal.signal);
    const rejected = expect(cancelled).rejects.toMatchObject({ name: "AbortError" });
    signal.abort();
    const worker = ControlledWorker.instances[0];
    worker.finish("one");
    await rejected; await first;
    expect(worker.posted).toHaveLength(1);
  });

  it("실행 중 취소 응답이 다음 요청의 응답을 덮지 않는다", async () => {
    const { runCoreAsync } = await import("@/shared/core");
    const signal = new AbortController();
    const first = runCoreAsync({ op: "bodyPreview", text: "stale" }, signal.signal);
    const rejected = expect(first).rejects.toMatchObject({ name: "AbortError" });
    const second = runCoreAsync({ op: "bodyPreview", text: "current" });
    signal.abort();
    const worker = ControlledWorker.instances[0];
    worker.finish("stale"); worker.finish("current");
    await rejected;
    expect(await second).toBe("current");
  });

  it("worker 실패로 대기 요청을 멈추지 않고 다음 요청에서 새 worker를 만든다", async () => {
    const { runCoreAsync } = await import("@/shared/core");
    const a = runCoreAsync({ op: "bodyPreview", text: "one" });
    const b = runCoreAsync({ op: "bodyPreview", text: "two" });
    const rejected = [expect(a).rejects.toThrow("worker failed"), expect(b).rejects.toThrow("worker failed")];
    ControlledWorker.instances[0].onerror?.();
    await Promise.all(rejected);
    const c = runCoreAsync({ op: "bodyPreview", text: "recovered" });
    expect(ControlledWorker.instances[0].terminated).toBe(true);
    ControlledWorker.instances[1].finish("recovered");
    expect(await c).toBe("recovered");
  });
});
