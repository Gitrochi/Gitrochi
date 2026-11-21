import { createRoot } from "react-dom/client";
import { CodeText } from "@/shared/ui";

const pause = () => new Promise((resolve) => setTimeout(resolve, 20));

/** Diffs, blame and file history draw code through CodeText: token colours apply, changed-word marks keep the text */
export async function codeTextSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:600px";
  document.body.append(host);
  const root = createRoot(host);
  try {
    const line = 'const label = "ready"; // 12';
    root.render(<div><CodeText className="coded" text={line} language="TypeScript" marks={[[6, 11]]} markClassName="diff-word" /><CodeText className="plain" text="just words" language="Plain text" /></div>);
    for (let i = 0; i < 50 && !host.querySelector(".coded"); i++) await pause();
    const coded = host.querySelector<HTMLElement>(".coded"), plain = host.querySelector<HTMLElement>(".plain");
    if (!coded || !plain) return [false, "CodeText did not render"];
    if (coded.textContent !== line) return [false, `the text changed: ${coded.textContent}`];
    const kinds = ["keyword", "string", "comment"].filter((kind) => !coded.querySelector(`.code-token-${kind}`));
    if (kinds.length) return [false, `no ${kinds.join(", ")} token`];
    const keyword = getComputedStyle(coded.querySelector(".code-token-keyword")!).color, text = getComputedStyle(coded).color;
    if (keyword === text) return [false, `the keyword is not coloured (${keyword})`];
    if (coded.querySelector("mark.diff-word")?.textContent !== "label") return [false, `the changed word mark is wrong: ${coded.querySelector("mark")?.textContent}`];
    if (plain.children.length || plain.textContent !== "just words") return [false, "plain text was split into tokens"];
    return [true, "keyword, string and comment colours, the changed-word mark over them, plain text untouched"];
  } finally {
    root.unmount();
    host.remove();
  }
}
