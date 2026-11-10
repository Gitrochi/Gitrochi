/** Reading a CI job's log, shared by the Actions page and a request's Checks. (macOS: ActionsPage) */
const errorWord = /(^|[^A-Za-z_-])(error|fatal)([^A-Za-z_-]|$)/i;
const failWord = /(^|[^A-Za-z_-])FAIL(ED|URE)?([^A-Za-z_-]|$)/;
const stamp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z /;
// eslint-disable-next-line no-control-regex
const colour = /\u001b\[[0-9;]*[A-Za-z]/g;

/** A log as a person reads it: without the runner's time stamps, colour codes and bookkeeping lines (macOS: ActionsPage.lines) */
export function logLines(log: string): string[] {
  return log.split("\n").flatMap((raw) => {
    const line = raw.replace(/\r$/, "").replace(stamp, "").replace(colour, "");
    const marker = /^##\[([^\]]+)\](.*)$/.exec(line);
    if (!marker) return [line];
    const [, kind, rest] = marker;
    return kind === "group" ? [rest] : kind === "error" ? [`Error: ${rest}`] : kind === "warning" ? [`Warning: ${rest}`] : kind === "notice" ? [`Notice: ${rest}`] : [];
  });
}

/** A line the log marks: it names an error, or FAIL in capitals as test runners print it */
export const isLogError = (line: string) => errorWord.test(line) || failWord.test(line);
