import type { RepositoryTreeEntry } from "@/entities/git";
import { buildHTMLPreview } from "@/widgets/local-workbench";

/** Browser-DOM checks for the inert parser, reparsed document and repeated-asset budgets. */
export async function codePreviewSelfTest(): Promise<void> {
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const entry = (path: string, size = 100, kind: RepositoryTreeEntry["kind"] = "file"): RepositoryTreeEntry => ({ path, size, kind, mode: kind === "file" ? "100644" : "120000", oid: "a".repeat(40) });
  const pixel = "data:image/gif;base64," + btoa("GIF89a" + "x".repeat(200_000));
  const files = [entry("pages/styles/site.css"), entry("pages/styles/nested.css"), entry("pages/images/pixel.gif", 200_006), entry("pages/styles/linked.css", 100, "symlink")];
  const reads: string[] = [];
  const text = '<meta http-equiv="refresh" content="0;url=https://example.invalid"><base href="https://example.invalid"><script>parent.previewScriptRan=true</script><iframe src="https://example.invalid"></iframe><link rel="stylesheet" href="styles/site.css"><link rel="stylesheet" href="styles/linked.css"><link rel="stylesheet" href="https://example.invalid/site.css"><h1 onclick="alert(1)">Preview fixture</h1><a href="https://example.invalid" target="_top">Link</a><img src="images/pixel.gif"><img src="https://example.invalid/pixel.gif"><form action="https://example.invalid"><button formaction="https://example.invalid">Submit</button></form><svg><foreignObject><iframe src="https://example.invalid"></iframe></foreignObject></svg>';
  const html = await buildHTMLPreview(text, "pages/index.html", files, async (file) => {
    reads.push(file.path);
    return file.path.endsWith("site.css") ? { text: '@import "nested.css"; .hero { color: rgb(23, 45, 67); background: url(../images/pixel.gif); }' }
      : file.path.endsWith("nested.css") ? { text: '/* </style><meta http-equiv="refresh" content="0;url=https://example.invalid"> */ p { font-weight: bold; }' }
      : { image: pixel };
  });
  const parsed = new DOMParser().parseFromString(html, "text/html");
  check(!parsed.querySelector("script, iframe, base, svg, link, meta[http-equiv='refresh']"), "HTML preview retained active content or CSS raw-text injection");
  check(![...parsed.querySelectorAll("*")].some((element) => [...element.attributes].some((attribute) => attribute.name.startsWith("on"))), "HTML preview retained event handlers");
  check(!parsed.querySelector("a[href], form[action], button[formaction], [target]"), "HTML preview retained navigation URLs");
  check(parsed.querySelector('meta[http-equiv="Content-Security-Policy"]')?.getAttribute("content")?.includes("connect-src 'none'"), "HTML preview did not install its restrictive CSP");
  check([...parsed.querySelectorAll("style")].some((style) => style.textContent?.includes("rgb(23, 45, 67)")) && parsed.querySelector('img[src^="data:image/gif"]'), "HTML preview did not inline committed CSS and raster images");
  check(!reads.includes("pages/styles/linked.css") && reads.length === 3, "HTML preview followed a symbolic link or read a remote resource");
  const repeated = await buildHTMLPreview('<img src="images/pixel.gif">'.repeat(100), "pages/index.html", files, async () => ({ image: pixel }));
  check(repeated.length < 16_000_000 && (repeated.match(/src="data:image\/gif/g)?.length ?? 0) < 60, "Repeated cached images exceeded the emitted preview budget");
  const cssText = "p{color:red}".repeat(20_000), shared = [entry("pages/main.css"), entry("pages/shared.css", cssText.length)];
  let sharedReads = 0;
  const repeatedCSS = await buildHTMLPreview('<link rel="stylesheet" href="main.css">'.repeat(100), "pages/index.html", shared, async (file) => { sharedReads++; return { text: file.path.endsWith("main.css") ? '@import "shared.css";'.repeat(100) : cssText }; });
  check(repeatedCSS.length < 16_000_000 && sharedReads === 2, "Repeated CSS imports exceeded the assembly or immutable-read budget");
  let limitedReads = 0;
  const many = Array.from({ length: 100 }, (_, index) => entry(`pages/image-${index}.gif`, 6));
  await buildHTMLPreview(many.map((file) => `<img src="${file.path.split("/").at(-1)}">`).join(""), "pages/index.html", many, async () => { limitedReads++; return { image: "data:image/gif;base64," + btoa("GIF89a") }; });
  check(limitedReads === 20, "HTML preview exceeded its unique asset limit");
}
