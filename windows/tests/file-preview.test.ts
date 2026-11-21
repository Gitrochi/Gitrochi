import { describe, expect, it } from "vitest";
import { highlightCode, highlightSql, jsonTree, parseDelimited, previewKind, previewPage } from "../src/entities/terminal/lib/file-preview";
import { linkTokens } from "../src/entities/terminal/lib/terminal-word";

const words = { cut: "cut", empty: "empty", size: (rows: number, columns: number) => `${rows}x${columns}` };

describe("Ctrl-click words in a terminal line", () => {
  it("finds paths in git and ls output", () => {
    expect(linkTokens("?? preview-samples/schema.sql").map((t) => t.text)).toEqual(["preview-samples/schema.sql"]);
    // ls pads columns with tabs; the buffer may hold NUL cells there
    expect(linkTokens("chart.svg\u0000\u0000schema.sql\tinventory.tsv").map((t) => t.text)).toEqual(["chart.svg", "schema.sql", "inventory.tsv"]);
    expect(linkTokens(" src/app.ts:12:4: error").map((t) => t.text)).toEqual(["src/app.ts:12:4"]);
    expect(linkTokens("see (notes.md).")).toEqual([{ start: 5, end: 13, text: "notes.md" }]);
    expect(linkTokens("open http://localhost:3000/ now").map((t) => t.text)).toEqual(["http://localhost:3000/"]);
  });
  it("leaves plain words and numbers alone", () => {
    expect(linkTokens("2 files changed, 10 insertions(+) v1.2.3 12:30")).toEqual([]);
  });
  it("takes paths with spaces as one link, longest file-like end first", () => {
    const line = 'open "/Users/me/Downloads/Trip plan (1 1~1 7).xlsx" now';
    const [token] = linkTokens(line);
    expect(token.text).toBe("/Users/me/Downloads/Trip plan (1 1~1 7).xlsx");
    expect(token.candidates?.[0]).toBe(token.text);
    expect(line.slice(token.start, token.end)).toBe(token.text);
    expect(linkTokens("C:\\Users\\me\\Downloads\\Hold report 14.pdf").map((t) => t.text)).toEqual(["C:\\Users\\me\\Downloads\\Hold report 14.pdf"]);
    expect(linkTokens("~/Downloads/a b.pdf: done.").map((t) => t.text)).toEqual(["~/Downloads/a b.pdf"]);
  });
  it("keeps separate paths and plain spaced words apart", () => {
    expect(linkTokens("/a/x.txt /b/y.txt").map((t) => t.text)).toEqual(["/a/x.txt", "/b/y.txt"]);
    expect(linkTokens("/a/x.txt  notes.md").map((t) => t.text)).toEqual(["/a/x.txt", "notes.md"]);
    expect(linkTokens("/usr/bin is here").map((t) => t.text)).toEqual(["/usr/bin"]);
    expect(linkTokens("open http://localhost:3000/ and docs.md").map((t) => t.text)).toEqual(["http://localhost:3000/", "docs.md"]);
  });
});

describe("file previews", () => {
  it("chooses the preview by extension", () => {
    expect(previewKind("db/schema.SQL")).toEqual({ kind: "sql" });
    expect(previewKind("C:\\work\\orders.csv")).toEqual({ kind: "table", separator: "," });
    expect(previewKind("a.tsv")).toEqual({ kind: "table", separator: "\t" });
    expect(previewKind("report.pdf")).toEqual({ kind: "native", mime: "application/pdf" });
    expect(previewKind("Makefile")).toEqual({ kind: "text" });
  });
  it("highlights SQL and escapes it", () => {
    const html = highlightSql("SELECT name -- c\nFROM t WHERE x = 'a''<b>' AND n > 10;");
    expect(html).toContain('<span class="keyword">SELECT</span>');
    expect(html).toContain('<span class="comment">-- c</span>');
    expect(html).toContain("<span class=\"string\">'a''&lt;b&gt;'</span>");
    expect(html).toContain('<span class="number">10</span>');
    expect(html).not.toContain("<b>");
  });
  it("parses quoted CSV fields", () => {
    const rows = parseDelimited('id,name\r\n1,"Mouse, wireless"\n2,"say ""hi"""\n3,"two\nlines"\n', ",");
    expect(rows).toEqual([["id", "name"], ["1", "Mouse, wireless"], ["2", 'say "hi"'], ["3", "two\nlines"]]);
  });
  it("builds pages without scripts", () => {
    const table = previewPage("o.csv", "a,b\n<script>,2\n", { kind: "table", separator: "," }, false, words);
    expect(table).toContain("1x2");
    expect(table).toContain("&lt;script&gt;");
    expect(table).not.toContain("<script>");
    expect(table).toContain("default-src 'none'");
    expect(previewPage("c.json", '{"a":', { kind: "json" }, false, words)).toContain('<pre class="code">{&quot;a&quot;:</pre>');
    expect(previewPage("big.txt", "x", { kind: "text" }, true, words)).toContain('<p class="note">cut</p>');
    const tree = jsonTree({ b: [1, null], a: true });
    expect(tree.indexOf('class="key">a<')).toBeLessThan(tree.indexOf('class="key">b<'));
    expect(tree).toContain('<span class="keyword">null</span>');
  });
});

describe("source code previews", () => {
  it("opens code files in the code reader's colours and leaves plain text alone", () => {
    expect(previewKind("src/app.ts")).toEqual({ kind: "code", language: "TypeScript" });
    expect(previewKind("main.RS")).toEqual({ kind: "code", language: "Rust" });
    expect(previewKind("notes.md")).toEqual({ kind: "text" });
    expect(previewKind("README")).toEqual({ kind: "text" });
  });
  it("colours tokens in the page's own classes and escapes the rest", () => {
    expect(highlightCode('const a = "<b>"; // x', "TypeScript")).toBe('<span class="keyword">const</span> a = <span class="string">&quot;&lt;b&gt;&quot;</span>; <span class="comment">// x</span>');
    expect(previewPage("a.py", "def f(): pass", { kind: "code", language: "Python" }, false, { cut: "cut", empty: "empty", size: () => "" })).toContain('<span class="keyword">def</span>');
  });
});
