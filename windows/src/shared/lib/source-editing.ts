/** Textarea offsets use normalized LF; unchanged file bytes retain their original BOM and line endings. */
export const editorText = (source: string) => source.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");

export function applyEditorText(source: string, next: string): string {
  const before = editorText(source);
  if (before === next) return source;
  let prefix = 0, suffix = 0;
  while (prefix < before.length && prefix < next.length && before[prefix] === next[prefix]) prefix++;
  while (suffix < before.length - prefix && suffix < next.length - prefix && before[before.length - 1 - suffix] === next[next.length - 1 - suffix]) suffix++;
  const offset = (position: number) => {
    let raw = source.startsWith("\uFEFF") ? 1 : 0, display = 0;
    while (display < position && raw < source.length) { if (source[raw] === "\r" && source[raw + 1] === "\n") raw++; raw++; display++; }
    return raw;
  };
  const ending = source.includes("\r\n") ? "\r\n" : source.includes("\r") && !source.includes("\n") ? "\r" : "\n";
  const inserted = next.slice(prefix, next.length - suffix).replace(/\n/g, ending);
  return source.slice(0, offset(prefix)) + inserted + source.slice(offset(before.length - suffix));
}

/** Indent selected logical lines, excluding a following line selected only by its leading newline. */
export function indentEditorText(text: string, start: number, end: number, outdent: boolean, indent = "  ") {
  if (start === end && !outdent) return { text: text.slice(0, start) + indent + text.slice(end), start: start + indent.length, end: start + indent.length };
  const first = start === 0 ? 0 : text.lastIndexOf("\n", start - 1) + 1;
  const last = end > start && text[end - 1] === "\n" ? end - 1 : end;
  const tail = text.indexOf("\n", last);
  const stop = tail < 0 ? text.length : tail;
  const original = text.slice(first, stop).split("\n");
  let delta = 0, firstDelta = 0;
  const changed = original.map((line, index) => {
    const remove = line.startsWith("\t") ? 1 : Math.min(indent.length, line.match(/^ */)?.[0].length ?? 0);
    const change = outdent ? -remove : indent.length;
    delta += change; if (!index) firstDelta = change;
    return outdent ? line.slice(remove) : indent + line;
  }).join("\n");
  return { text: text.slice(0, first) + changed + text.slice(stop), start: Math.max(first, start + firstDelta), end: Math.max(first, end + delta) };
}

export function editorLineRange(text: string, line: number) {
  let start = 0;
  for (let current = 1; current < line; current++) { const next = text.indexOf("\n", start); if (next < 0) break; start = next + 1; }
  const end = text.indexOf("\n", start);
  return { start, end: end < 0 ? text.length : end };
}
