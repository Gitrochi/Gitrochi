import { useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { Inspector } from "@/widgets/inspector";
import { RepoStore } from "@/entities/repo";
import { emptyStatus } from "@/entities/git";
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
    const [working, detail] = await workingChangesTransitions(host, root);
    return [working, JSON.stringify({ margins: samples, working: detail })];
  } finally { root.unmount(); host.remove(); }
}

/** Exercise pane cleanup alongside the real composer, impact card and empty state. */
async function workingChangesTransitions(host: HTMLElement, root: Root): Promise<[boolean, unknown]> {
  const store = new RepoStore();
  store.selection = { kind: "wip" };
  store.headBranch = "fixture";
  const changes = (staged: boolean, count: number) => Array.from({ length: count }, (_, i) => ({ path: `src/fixture-${i}.ts`, oldPath: null, kind: "modified" as const, staged }));
  const staged = { ...emptyStatus(), staged: changes(true, 1) };
  const both = { ...emptyStatus(), staged: changes(true, 20), unstaged: changes(false, 20) };
  const states = [staged, emptyStatus(), both, emptyStatus(), staged, emptyStatus()];
  let transitions = 0;
  for (const width of [280, 330, 420]) for (const height of [480, 720.5]) for (const mode of ["bounded", "natural", "bounded"]) {
    root.render(<div className={`workspace-changes-list shared-stack-regression ${mode}`} style={{ width, minWidth: 0, maxWidth: "none", height, display: "flex", flexDirection: "column", overflow: "auto" }}>
      <style>{`
        .shared-stack-regression.bounded > .col { height:100%!important; flex:1!important; min-height:0!important; }
        .shared-stack-regression.bounded .panel-scroll { flex:1!important; overflow:auto!important; }
        .shared-stack-regression.natural > .col { height:auto!important; flex:none!important; min-height:100%!important; }
        .shared-stack-regression.natural .panel-scroll { flex:none!important; overflow:visible!important; }
      `}</style>
      <Inspector store={store} />
    </div>);
    await pause();
    for (const status of states) {
      store.status = status;
      store.busy = status.staged.length ? "Fixture commit" : null;
      store.summary = status.staged.length ? "Fixture summary" : "";
      store.changed();
      const expected = Number(status.staged.length > 0) + Number(status.unstaged.length > 0);
      const panes = () => [...host.querySelectorAll<HTMLElement>(".shared-pane")];
      if (!await until(() => panes().length === expected && !!host.querySelector(".panel-scroll")))
        return [false, `Working Changes did not survive ${mode} ${width}×${height}, panes=${expected}`];
      await pause();
      const measured = host.querySelector<HTMLElement>(".panel-scroll")!;
      const before = measured.getBoundingClientRect().height;
      const heights = panes().map((pane) => pane.clientHeight);
      if (expected === 2 && heights.some((value) => value < 96)) return [false, `Pane floors were lost: ${heights}`];
      if (mode === "bounded" && expected === 2 && Math.abs(heights[0] - heights[1]) > 1)
        return [false, `Bounded panes did not share the column: ${heights}`];
      if (mode === "natural" && panes().some((pane) => pane.scrollHeight > pane.clientHeight + 1))
        return [false, `Natural panes were constrained: ${heights}`];
      if (!expected && !host.querySelector(".card")) return [false, "The clean working tree card did not render"];
      await pause();
      if (!measured.isConnected || Math.abs(measured.getBoundingClientRect().height - before) > 1)
        return [false, `Working Changes height did not settle: ${mode} ${width}×${height}, panes=${expected}`];
      transitions++;
    }
  }
  return [true, { transitions, widths: [280, 330, 420], heights: [480, 720.5], modes: ["bounded", "natural", "bounded"], emptyStates: true, multiplePanes: true }];
}
