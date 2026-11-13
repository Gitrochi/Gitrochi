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

/** One line of a log as the failed-check block draws it (macOS: JobLog.Line) */
export interface LogLine { n: number; text: string; isError: boolean }

const exitCode = /exit code [1-9]/;

/** Lines numbered from 1; the ones that report a failure are marked (macOS: JobLog.numbered) */
export const numberedLog = (lines: string[]): LogLine[] =>
  lines.map((text, index) => ({ n: index + 1, text, isError: isLogError(text) || exitCode.test(text) }));

/** A job's log as numbered lines, without the empty line a final newline leaves */
export function checkLogLines(body: string): LogLine[] {
  const lines = logLines(body);
  if (lines.length && !lines[lines.length - 1]) lines.pop();
  return numberedLog(lines);
}

/** The number of the first line that reports a failure */
export const firstError = (lines: LogLine[]): number | null => lines.find((line) => line.isError)?.n ?? null;

/** How many lines a log folds away at first: it opens a few lines before its first error, or on its last two hundred (macOS: JobLog.firstShown) */
export function firstLogLine(lines: LogLine[]): number {
  const error = lines.findIndex((line) => line.isError);
  return error >= 0 ? Math.max(0, error - 3) : Math.max(0, lines.length - 200);
}

// How test runners name a failed test, one family per runner; a log is read with the first family that finds any.
const testFailures: ((line: string) => string | null)[] = [
  // XCTest: Test Case '-[AppTests.SearchTests testQuery]' failed, or 'SearchTests.testQuery'
  (line) => {
    const found = /Test Case '(?:-\[)?([^']+?)\]?' failed/.exec(line);
    if (!found) return null;
    const [type, method] = found[1].split(" ");
    return method ? `${type.split(".").pop()}.${method}` : found[1];
  },
  // Go: --- FAIL: TestQuery (0.00s)
  (line) => /^\s*--- FAIL: (\S+)/.exec(line)?.[1] ?? null,
  // cargo: test search::tests::query ... FAILED
  (line) => /^test (\S+) \.\.\. FAILED\s*$/.exec(line)?.[1] ?? null,
  // pytest: FAILED tests/test_search.py::test_query - AssertionError
  (line) => /^FAILED (\S+::\S+)/.exec(line)?.[1] ?? null,
  // Vitest: FAIL tests/search.test.ts > search > keeps the query
  (line) => /^\s*FAIL\s+(\S+ > .+?)\s*$/.exec(line)?.[1] ?? null,
  // Jest, Mocha and Vitest: ✕ keeps the query (12 ms), × keeps the query 12ms
  (line) => /^\s*[✕×✗]\s+(.+?)(?:\s+\(?\d+(?:\.\d+)?\s*m?s\)?)?\s*$/.exec(line)?.[1] ?? null,
];
// linters and compilers mark their diagnostics with × too, so the last rule needs a test runner's summary in the log
const runnerSummary = /^\s*(?:Tests?:|Test Files|Test Suites:|\d+ failing\b)/;

/** The tests a log says failed, by name, in order and once each (macOS: JobLog.failedTests) */
export function failedTests(lines: string[]): string[] {
  for (const [family, read] of testFailures.entries()) {
    if (family === testFailures.length - 1 && !lines.some((line) => runnerSummary.test(line))) continue;
    const names = [...new Set(lines.flatMap((line) => read(line) ?? []))];
    if (names.length) return names;
  }
  return [];
}

/** The names a "1 test failed:" caption lists: the first three, and a sign that there are more (macOS: JobLog.testNames) */
export const testNames = (tests: string[]): string => tests.slice(0, 3).join(", ") + (tests.length > 3 ? ", …" : "");
