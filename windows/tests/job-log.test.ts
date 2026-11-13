import { describe, expect, it } from "vitest";
import { checkLogLines, failedTests, firstError, firstLogLine, isLogError, logLines, numberedLog, testNames } from "@/shared/lib/job-log";

describe("job log", () => {
  it("reads a log without the runner's time stamps, colour codes and bookkeeping lines", () => {
    expect(logLines("2026-11-06T00:45:22.6820373Z ##[group]Run tests\r\n2026-11-06T00:45:22.68Z \u001b[36;1mmake\u001b[0m\n##[endgroup]\n##[error]Process completed\n##[start-action id=1]")).toEqual(["Run tests", "make", "Error: Process completed"]);
  });

  it("marks the lines that name an error, not words that only contain one", () => {
    for (const line of ["TerminalFocusTests.swift:58: error: XCTAssertTrue failed", "Error: Process completed with exit code 1.", "FAIL: Update the dependency lockfile", "##[error]boom", "fatal: not a git repository"])
      expect(isLogError(line), line).toBe(true);
    for (const line of ["Test Suite 'TerminalFocusTests' started.", "Checked 12 terrors, errorless", "Executed 231 tests, with 1 failure", "curl --retry 10 --show-error --fail https://example.test", "CACHE_ON_FAILURE: false"])
      expect(isLogError(line), line).toBe(false);
  });

  it("numbers a log and finds its first error", () => {
    const lines = checkLogLines("Test Suite started.\r\nSearch.swift:58: error: XCTAssertTrue failed\nterrors and failedover are words too\nProcess completed with exit code 1.\n");
    expect(lines.map((line) => line.n)).toEqual([1, 2, 3, 4]);
    expect(lines.map((line) => line.isError)).toEqual([false, true, false, true]);
    expect(firstError(lines)).toBe(2);
    expect(firstError(checkLogLines("All good\nexit code 0"))).toBeNull();
    expect(checkLogLines("")).toEqual([]);
    expect(numberedLog(["one", "FAILED"])).toEqual([{ n: 1, text: "one", isError: false }, { n: 2, text: "FAILED", isError: true }]);
  });

  it("opens a log a few lines before its first error, or on its last two hundred lines", () => {
    expect(firstLogLine(numberedLog(Array.from({ length: 46 }, (_, index) => (index === 40 ? "x.swift:58: error: failed" : `line ${index + 1}`))))).toBe(37);
    expect(firstLogLine(numberedLog(Array.from({ length: 500 }, (_, index) => `line ${index + 1}`)))).toBe(300);
    expect(firstLogLine(numberedLog(["one"]))).toBe(0);
    expect(firstLogLine(numberedLog(["error: at once", "two"]))).toBe(0);
  });

  it("names the failed tests the way each runner prints them", () => {
    expect(failedTests([
      "Test Case '-[AppTests.TerminalFocusTests testFocusAfterClick]' passed (0.004 seconds).",
      "Test Case '-[AppTests.TerminalFocusTests testFocusAfterPaste]' failed (0.031 seconds).",
      "Test Suite 'TerminalFocusTests' failed.",
    ])).toEqual(["TerminalFocusTests.testFocusAfterPaste"]);
    expect(failedTests(["Test Case 'SearchPanelUITests.testKeepsQueryAfterSwitch' failed (3.871 seconds)."])).toEqual(["SearchPanelUITests.testKeepsQueryAfterSwitch"]);
    expect(failedTests(["=== RUN   TestQuery", "--- FAIL: TestQuery (0.00s)", "    --- FAIL: TestQuery/empty (0.00s)", "FAIL"])).toEqual(["TestQuery", "TestQuery/empty"]);
    expect(failedTests(["test search::tests::query ... ok", "test search::tests::empty ... FAILED"])).toEqual(["search::tests::empty"]);
    expect(failedTests(["FAILED tests/test_search.py::test_query - AssertionError", "FAILED tests/test_search.py::test_query - AssertionError"])).toEqual(["tests/test_search.py::test_query"]);
    expect(failedTests([" FAIL  tests/search.test.ts > search > keeps the query", "   × keeps the query 12ms"])).toEqual(["tests/search.test.ts > search > keeps the query"]);
    expect(failedTests(["  ✕ keeps the query (12 ms)", "  ✓ shows results (3 ms)"])).toEqual(["keeps the query"]);
    expect(failedTests(["Build failed", "error: linker command failed with exit code 1"])).toEqual([]);
  });

  it("lists the first three failed tests in a caption", () => {
    expect(testNames(["a"])).toBe("a");
    expect(testNames(["a", "b", "c"])).toBe("a, b, c");
    expect(testNames(["a", "b", "c", "d"])).toBe("a, b, c, …");
  });
});
