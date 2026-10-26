import { describe, expect, it } from "vitest";
import { canLoadImage, markdownRefs } from "@/entities/git/model/types";
import { type MdBlock, type MdInline, type MdRefs, parseMarkdown } from "@/shared/lib/markdown";

const text = (t: string): MdInline => ({ kind: "text", text: t });
const para = (...inlines: MdInline[]): MdBlock => ({ kind: "paragraph", inlines });
const one = (md: string, refs?: MdRefs) => {
  const b = parseMarkdown(md, refs);
  expect(b).toHaveLength(1);
  return b[0];
};
const inl = (md: string, refs?: MdRefs) => {
  const b = one(md, refs);
  if (b.kind !== "paragraph") throw new Error("not a paragraph: " + b.kind);
  return b.inlines;
};
/** Every link and image URL anywhere in the tree */
function urls(blocks: MdBlock[]): string[] {
  const out: string[] = [];
  const walkInline = (n: MdInline) => {
    if (n.kind === "link") out.push(n.href);
    if (n.kind === "image") out.push(n.src);
    if ("children" in n) n.children.forEach(walkInline);
  };
  const walk = (b: MdBlock) => {
    if (b.kind === "paragraph" || b.kind === "heading") b.inlines.forEach(walkInline);
    if (b.kind === "quote") b.blocks.forEach(walk);
    if (b.kind === "list") b.items.forEach((i) => i.blocks.forEach(walk));
    if (b.kind === "details") {
      b.summary.forEach(walkInline);
      b.blocks.forEach(walk);
    }
    if (b.kind === "table") [...b.head, ...b.rows.flat()].flat().forEach(walkInline);
  };
  blocks.forEach(walk);
  return out;
}

describe("markdown blocks", () => {
  it("headings, paragraphs and rules", () => {
    expect(parseMarkdown("# Title\n\nSome text\n\n---\n## Next ##")).toEqual([
      { kind: "heading", level: 1, inlines: [text("Title")] },
      para(text("Some text")),
      { kind: "rule" },
      { kind: "heading", level: 2, inlines: [text("Next")] },
    ]);
    expect(one("Title\n===")).toEqual({ kind: "heading", level: 1, inlines: [text("Title")] });
    expect(one("#123 is not a heading")).toEqual(para(text("#123 is not a heading")));
  });

  it("keeps line breaks inside a paragraph like GitHub comments", () => {
    expect(inl("first\nsecond  \nthird")).toEqual([text("first"), { kind: "break" }, text("second"), { kind: "break" }, text("third")]);
  });

  it("fenced and indented code", () => {
    expect(one("```ts\nconst a = 1;\n\n  b();\n```")).toEqual({ kind: "code", lang: "ts", text: "const a = 1;\n\n  b();" });
    expect(one("~~~\nunclosed")).toEqual({ kind: "code", lang: "", text: "unclosed" });
    expect(one("    indented\n    code")).toEqual({ kind: "code", lang: "", text: "indented\ncode" });
  });

  it("nested lists, ordered start and task items", () => {
    const b = one("- a\n  - b\n- [x] done\n- [ ] todo");
    expect(b).toEqual({
      kind: "list",
      ordered: false,
      start: 1,
      items: [
        { task: null, blocks: [para(text("a")), { kind: "list", ordered: false, start: 1, items: [{ task: null, blocks: [para(text("b"))] }] }] },
        { task: true, blocks: [para(text("done"))] },
        { task: false, blocks: [para(text("todo"))] },
      ],
    });
    const o = one("3. three\n4. four");
    expect(o.kind === "list" && o.ordered && o.start).toBe(3);
    expect(parseMarkdown("Text\n- item")[1].kind).toBe("list");
    expect(parseMarkdown("Text\n2. not a list")).toHaveLength(1);
  });

  it("quotes with lazy continuation", () => {
    expect(one("> quoted\nlazy\n> more")).toEqual({ kind: "quote", blocks: [para(text("quoted"), { kind: "break" }, text("lazy"), { kind: "break" }, text("more"))] });
  });

  it("tables with alignment and escaped pipes", () => {
    expect(one("| a | b | c |\n|:--|:-:|--:|\n| 1 | `x\\|y` |\n| 2 | 3 | 4 | 5 |")).toEqual({
      kind: "table",
      align: ["left", "center", "right"],
      head: [[text("a")], [text("b")], [text("c")]],
      rows: [
        [[text("1")], [{ kind: "code", text: "x|y" }], []],
        [[text("2")], [text("3")], [text("4")]],
      ],
    });
    expect(one("a | b\n--- | ---").kind).toBe("table");
    expect(parseMarkdown("a | b\n---")[0].kind).toBe("heading");
  });

  it("details with summary, and hidden HTML comments", () => {
    expect(parseMarkdown("<!-- template hint\nmore -->\n<details>\n<summary>Logs</summary>\n\n```\nlog\n```\n</details>\nafter")).toEqual([
      { kind: "details", summary: [text("Logs")], blocks: [{ kind: "code", lang: "", text: "log" }] },
      para(text("after")),
    ]);
    expect(parseMarkdown("<!-- hint --> visible")).toEqual([para(text("visible"))]);
  });

  it("drops paragraphs that only held tags", () => {
    expect(parseMarkdown('<p align="center">\n<img src="https://example.com/a.png" alt="Logo">\n</p>')).toEqual([para({ kind: "image", src: "https://example.com/a.png", alt: "Logo" })]);
    expect(parseMarkdown("<div>\n</div>")).toEqual([]);
  });
});

describe("markdown inlines", () => {
  it("emphasis, strike and code", () => {
    expect(inl("**bold** *em* ***both*** ~~gone~~ `a*b*`")).toEqual([
      { kind: "strong", children: [text("bold")] },
      text(" "),
      { kind: "em", children: [text("em")] },
      text(" "),
      { kind: "strong", children: [{ kind: "em", children: [text("both")] }] },
      text(" "),
      { kind: "strike", children: [text("gone")] },
      text(" "),
      { kind: "code", text: "a*b*" },
    ]);
    expect(inl("*a **b** c*")).toEqual([{ kind: "em", children: [text("a "), { kind: "strong", children: [text("b")] }, text(" c")] }]);
    expect(inl("snake_case_name and 2 * 3 * 4")).toEqual([text("snake_case_name and 2 * 3 * 4")]);
    expect(inl("\\*not em\\* &amp; &lt;b&gt;")).toEqual([text("*not em* & <b>")]);
  });

  it("links, autolinks and images", () => {
    expect(inl("[site](https://example.com/a_(b) \"t\") and <https://example.com> or https://example.com/x.")).toEqual([
      { kind: "link", href: "https://example.com/a_(b)", children: [text("site")] },
      text(" and "),
      { kind: "link", href: "https://example.com", children: [text("https://example.com")] },
      text(" or "),
      { kind: "link", href: "https://example.com/x", children: [text("https://example.com/x")] },
      text("."),
    ]);
    expect(inl("![shot](https://example.com/s.png)")).toEqual([{ kind: "image", src: "https://example.com/s.png", alt: "shot" }]);
    expect(inl("(www.example.com)")).toEqual([text("("), { kind: "link", href: "http://www.example.com", children: [text("www.example.com")] }, text(")")]);
  });

  it("never keeps scripts, event handlers or unsafe link schemes", () => {
    const md = [
      "<script>alert(1)</script>",
      '<img src="x" onerror="alert(1)">',
      '<a href="javascript:alert(1)">click</a>',
      "[js](javascript:alert(1)) [data](data:text/html;base64,AAAA) [vb](VBScript:x) [enc](&#106;avascript:alert(1))",
      "![img](javascript:alert(1))",
      "<iframe src=\"https://example.com\"></iframe><style>body{}</style>",
    ].join("\n\n");
    const blocks = parseMarkdown(md);
    expect(urls(blocks)).toEqual([]);
    const all = JSON.stringify(blocks);
    expect(all).not.toMatch(/alert|onerror|iframe|<a|body\{/i);
    expect(all).toContain("click");
  });

  it("links #123, !123 and @name when the repository is known", () => {
    const refs: MdRefs = {
      issue: (n) => `https://gitlab.example.com/g/r/-/issues/${n}`,
      request: (n) => `https://gitlab.example.com/g/r/-/merge_requests/${n}`,
      user: (u) => `https://gitlab.example.com/${u}`,
    };
    expect(inl("Fixes #12, see !3 by @dev.one. Not a@b.com or C#1 or `#4`", refs)).toEqual([
      text("Fixes "),
      { kind: "link", href: "https://gitlab.example.com/g/r/-/issues/12", children: [text("#12")] },
      text(", see "),
      { kind: "link", href: "https://gitlab.example.com/g/r/-/merge_requests/3", children: [text("!3")] },
      text(" by "),
      { kind: "link", href: "https://gitlab.example.com/dev.one", children: [text("@dev.one")] },
      text(". Not a@b.com or C#1 or "),
      { kind: "code", text: "#4" },
    ]);
    expect(inl("#12")).toEqual([text("#12")]);
  });

  it("stays fast on text full of unmatched delimiters", () => {
    const md = "*_`[~".repeat(20000);
    const started = performance.now();
    parseMarkdown(md);
    expect(performance.now() - started).toBeLessThan(1000);
  });
});

describe("markdown links for a repository", () => {
  it("loads images only over https from the repository's own server", () => {
    const gh = { provider: "github" as const, remote: "origin", host: "github.com", path: "o/r" };
    expect(canLoadImage(gh, "https://github.com/user-attachments/assets/x")).toBe(true);
    expect(canLoadImage(gh, "https://private-user-images.githubusercontent.com/1/x.png")).toBe(true);
    expect(canLoadImage(gh, "http://github.com/x.png")).toBe(false);
    expect(canLoadImage(gh, "https://tracker.example.com/p.gif")).toBe(false);
    const gl = { provider: "gitlab" as const, remote: "origin", host: "gitlab.example.com:8443", path: "g/r" };
    expect(canLoadImage(gl, "https://gitlab.example.com/g/r/uploads/a.png")).toBe(true);
    expect(canLoadImage(gl, "https://user-images.githubusercontent.com/a.png")).toBe(false);
    expect(canLoadImage(null, "https://github.com/x.png")).toBe(false);
  });

  it("points #, ! and @ at the right pages", () => {
    const gh = markdownRefs({ provider: "github", remote: "origin", host: "github.com", path: "o/r" });
    expect([gh.issue("5"), gh.request, gh.user("kim")]).toEqual(["https://github.com/o/r/issues/5", undefined, "https://github.com/kim"]);
    const gl = markdownRefs({ provider: "gitlab", remote: "origin", host: "gitlab.example.com", path: "g/r" });
    expect([gl.issue("5"), gl.request?.("3")]).toEqual(["https://gitlab.example.com/g/r/-/issues/5", "https://gitlab.example.com/g/r/-/merge_requests/3"]);
  });
});
