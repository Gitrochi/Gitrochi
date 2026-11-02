// A dependency-free fixture DOM for the exact selectors used by the adapter.
// Live Chrome verification remains separate; this is not a browser replacement.
class Element {
  constructor(tag, attributes = {}, parent = null) {
    this.tagName = tag.toUpperCase();
    this.attributes = attributes;
    this.parentElement = parent;
    this.nodes = [];
    this.value = "";
    this.isConnected = true;
  }
  get children() { return this.nodes.filter((node) => typeof node !== "string"); }
  get textContent() { return this.nodes.map((node) => typeof node === "string" ? node : node.textContent).join(""); }
  set textContent(value) { this.nodes = [value]; }
  get id() { return this.attributes.id ?? ""; }
  get previousElementSibling() {
    const siblings = this.parentElement?.children ?? [];
    return siblings[siblings.indexOf(this) - 1] ?? null;
  }
  hasAttribute(name) { return Object.hasOwn(this.attributes, name); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  setAttribute(name, value) { this.attributes[name] = value; }
  matches(selector) {
    const tag = /^[a-z][a-z0-9-]*/i.exec(selector)?.[0];
    if (tag && tag.toUpperCase() !== this.tagName) return false;
    const id = /#([\w-]+)/.exec(selector)?.[1];
    if (id && this.id !== id) return false;
    return [...selector.matchAll(/\[([\w-]+)(?:=["']?([^\]"']*)["']?)?\]/g)].every(([, name, value]) => this.hasAttribute(name) && (value === undefined || this.getAttribute(name) === value));
  }
  querySelectorAll(selector) {
    const selectors = selector.split(",").map((part) => part.trim());
    return this.children.flatMap((child) => [...(selectors.some((part) => child.matches(part)) ? [child] : []), ...child.querySelectorAll(selector)]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
}

export function parseFixture(html) {
  const root = new Element("document");
  let current = root;
  for (const token of html.match(/<!--[^]*?-->|<[^>]*>|[^<]+/g) ?? []) {
    if (token.startsWith("<!--")) continue;
    if (token.startsWith("</")) { current = current.parentElement ?? current; continue; }
    if (token.startsWith("<")) {
      const tag = /^<([\w-]+)/.exec(token)?.[1];
      if (!tag) continue;
      const attributes = {};
      const rest = token.slice(tag.length + 1, -1);
      for (const [, name, double, single, bare] of rest.matchAll(/([\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) attributes[name] = double ?? single ?? bare ?? "";
      const child = new Element(tag, attributes, current);
      current.nodes.push(child);
      if (!["input", "br", "hr", "meta", "link"].includes(tag)) current = child;
    } else current.nodes.push(token.replaceAll("&amp;", "&").replaceAll("&lt;", "<").replaceAll("&gt;", ">"));
  }
  return root;
}
