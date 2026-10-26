import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { Inspector } from "@/widgets/inspector";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** 실제 상세 화면을 좁혀 긴 참조·작성자·부모 커밋이 열 밖으로 새지 않는지 확인한다. */
export async function inspectorLayoutSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, run: ipc.run, http: ipc.http };
  const memory = new Map<string, unknown>([["avatarFetch", false], ["fileViewMode", "list"]]);
  const unexpected: string[] = [];
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: "240px", height: "900px", display: "flex", visibility: "hidden" });
  document.body.append(host);
  const root = createRoot(host), store = new RepoStore(), sha = "a".repeat(40);
  const branch = "codex/" + "long-unbroken-feature-name-".repeat(12);
  const author = "긴 작성자 이름 Alexander Repository Contributor", email = "very-long-author-".repeat(12) + "@example.invalid";
  const summary = "커밋 제목 첫 글자를 보존합니다 — " + "Long summary for compact inspector validation. ".repeat(5);
  const widths: { width: number; bounded: boolean; authorWidth: number; scrollWidth: number; contentWidth: number }[] = [];
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); };
    ipc.run = async () => { unexpected.push("process"); throw new Error("Fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Fixture blocked network"); };
    store.path = "C:/gitrochi-inspector-layout-fixture";
    store.selection = { kind: "commit", sha };
    store.detail = { sha, parents: ["b".repeat(40), "c".repeat(40), "d".repeat(40), "e".repeat(40)], author, email, date: 1792974000, committer: "VeryLongCommitter".repeat(30), committerEmail: email, commitDate: 1792977600, summary, body: "UnbrokenBodyIdentifier".repeat(50) };
    store.refsByCommit = new Map([[sha, [{ name: branch, kind: "local", isCurrent: true }, { name: "origin/" + branch, kind: "remote", isCurrent: false }]]]);
    store.explanations[sha] = "LongExplanationIdentifier".repeat(40);
    const path = "docs/" + "nested-long-folder/".repeat(8) + "report.md";
    store.detailFiles = [{ path, oldPath: null, staged: true, kind: "modified" }];
    store.detailStats = { [path]: { added: 123456, deleted: 98765 } };
    root.render(<Inspector store={store} />);
    const end = Date.now() + 2500;
    while (!host.querySelector(".commit-detail .card") && Date.now() < end) await pause(20);
    if (!host.querySelector(".commit-detail .card")) return [false, "Commit detail did not mount"];
    for (const width of [240, 280, 320]) {
      host.style.width = `${width}px`;
      await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
      const panel = host.querySelector<HTMLElement>(".panel-scroll")!, bounds = host.getBoundingClientRect();
      const controls = [...host.querySelectorAll<HTMLElement>(".ref-badge, .commit-author, .commit-author-date, .panel-scroll button, .file-row, .card > .selectable")];
      const bounded = controls.every((element) => { const rect = element.getBoundingClientRect(); return rect.width > 0 && rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1; });
      widths.push({ width, bounded, authorWidth: host.querySelector(".commit-author")!.getBoundingClientRect().width, scrollWidth: panel.scrollWidth, contentWidth: panel.clientWidth });
    }
    const refs = [...host.querySelectorAll<HTMLElement>(".ref-badge")];
    const refNames = [branch, "origin/" + branch];
    const fullNamesAvailable = refs.every((element, index) => element.title === refNames[index] && element.dataset.tip === refNames[index]);
    const identityAvailable = host.querySelector<HTMLElement>(".commit-author > span:first-child")?.title === author && host.querySelector<HTMLElement>(".commit-author > span:last-child")?.title === email;
    const titleAvailable = host.querySelector(".card > .selectable")?.textContent === summary;
    const parentsAvailable = host.querySelectorAll(".pill").length === 5;
    const ok = widths.every((item) => item.bounded && item.authorWidth >= item.width - 95 && item.scrollWidth <= item.contentWidth + 1) && fullNamesAvailable && identityAvailable && titleAvailable && parentsAvailable && unexpected.length === 0;
    return [ok, JSON.stringify({ widths, fullNamesAvailable, identityAvailable, titleAvailable, parentsAvailable, unexpected })];
  } finally {
    root.unmount(); await pause(20); host.remove();
    settings.get = original.get; settings.set = original.set; ipc.run = original.run; ipc.http = original.http;
  }
}
