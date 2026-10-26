import { coreBytes } from "./core.generated";

interface CoreExports extends WebAssembly.Exports {
  memory: WebAssembly.Memory;
  gitrochi_alloc(length: number): number;
  gitrochi_compute(pointer: number, length: number): number;
  gitrochi_graph(pointer: number, length: number): number;
  gitrochi_free(pointer: number, length: number): void;
}

let runtime: CoreExports | undefined;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** 외부 실행 권한·파일 접근이 없는 Rust 계산 코어. 네이티브 Swift와 동일한 요청 계약. */
export function runCore<T>(request: Record<string, unknown>): T {
  if (request.op === "graphCompact") return runGraph(request.input as Uint32Array) as T;
  if (!runtime) {
    const bytes = Uint8Array.from(atob(coreBytes), (c) => c.charCodeAt(0));
    runtime = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports as CoreExports;
  }
  const wasm = runtime;
  const input = encoder.encode(JSON.stringify(request));
  const pointer = wasm.gitrochi_alloc(input.length);
  let result = 0;
  let total = 0;
  try {
    new Uint8Array(wasm.memory.buffer, pointer, input.length).set(input);
    result = wasm.gitrochi_compute(pointer, input.length);
    const size = new DataView(wasm.memory.buffer).getBigUint64(result, true);
    if (size > BigInt(wasm.memory.buffer.byteLength - result - 8)) throw new Error("Invalid core response");
    total = Number(size) + 8;
    const response = JSON.parse(decoder.decode(new Uint8Array(wasm.memory.buffer, result + 8, Number(size)))) as { value?: T; error?: string };
    if (response.error) throw new Error(response.error);
    return response.value as T;
  } finally {
    // compute가 memory.grow를 할 수 있으므로 메모리 view를 호출 사이에 보관하지 않는다.
    wasm.gitrochi_free(pointer, input.length);
    if (result && total) wasm.gitrochi_free(result, total);
  }
}

/** 그래프는 문자열 JSON 왕복 대신 숫자만 공유한다. 결과 객체는 화면 경계에서 한 번 만든다. */
export function runGraph(input: Uint32Array): Uint32Array {
  if (!runtime) runCore({ op: "graph", commits: [] });
  const wasm = runtime!;
  const pointer = wasm.gitrochi_alloc(input.byteLength);
  let result = 0;
  let total = 0;
  try {
    new Uint8Array(wasm.memory.buffer, pointer, input.byteLength).set(new Uint8Array(input.buffer, input.byteOffset, input.byteLength));
    result = wasm.gitrochi_graph(pointer, input.byteLength);
    const size = Number(new DataView(wasm.memory.buffer).getBigUint64(result, true));
    total = size + 8;
    if (size < 8 || size % 4 || result + total > wasm.memory.buffer.byteLength) throw new Error("Invalid graph response");
    return new Uint32Array(new Uint8Array(wasm.memory.buffer, result + 8, size).slice().buffer);
  } finally {
    wasm.gitrochi_free(pointer, input.byteLength);
    if (result && total) wasm.gitrochi_free(result, total);
  }
}
