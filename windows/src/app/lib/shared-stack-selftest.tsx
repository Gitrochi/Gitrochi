import { useState } from "react";
import { createRoot } from "react-dom/client";
import { SharedPane, SharedStack } from "@/shared/ui";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 30));
async function until(test: () => boolean) {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(); }
  return false;
}

/** A collapsed section margin must not feed back into pane heights as content grows. */
export async function sharedStackSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: "240px", visibility: "hidden" });
  document.body.append(host);
  const root = createRoot(host);
  let resize = (_height: number) => {};
  function Fixture() {
    const [height, setHeight] = useState(8);
    resize = setHeight;
    return <SharedStack style={{ width: 240, padding: 0, overflow: "auto" }}>
      <div style={{ marginTop: 8 }}>
        <div style={{ height: 24 }}>Fixture heading</div>
        <SharedPane id="resizing"><div style={{ height }}>Fixture rows</div></SharedPane>
      </div>
    </SharedStack>;
  }
  const stack = () => host.querySelector<HTMLElement>(".shared-stack");
  const pane = () => host.querySelector<HTMLElement>(".shared-pane");
  const samples: Array<{ content: number; stack: number; pane: number; fixed: number }> = [];
  try {
    root.render(<Fixture />);
    if (!await until(() => pane()?.clientHeight === 8)) return [false, "Initial short pane did not mount"];
    for (const content of [1200, 8, 1800]) {
      resize(content);
      const ready = await until(() => content > 8 ? (pane()?.clientHeight ?? 0) >= 96 : pane()?.clientHeight === 8);
      if (!ready || !stack() || !pane()) return [false, `Pane did not resize for ${content}px content`];
      await pause();
      const outer = stack()!.getBoundingClientRect().height;
      const height = pane()!.getBoundingClientRect().height;
      samples.push({ content, stack: outer, pane: height, fixed: outer - height });
      if (Math.abs(outer - height - 32) > 1) return [false, `Section margin escaped the measured body: ${JSON.stringify(samples)}`];
      // The previous failure repeatedly added the escaped 8px margin until React unmounted.
      await pause();
      if (Math.abs(stack()!.getBoundingClientRect().height - outer) > 1) return [false, `Pane height kept growing: ${JSON.stringify(samples)}`];
    }
    return [true, JSON.stringify(samples)];
  } finally { root.unmount(); host.remove(); }
}
