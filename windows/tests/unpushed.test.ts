import { describe, expect, it } from "vitest";
import { parseUnpushed } from "@/entities/git";

describe("parseUnpushed", () => {
  it("reads one commit per line of rev-list", () => {
    expect([...parseUnpushed("a1\nb2\n\n", true)]).toEqual(["a1", "b2"]);
  });

  it("marks nothing in a repository without a remote", () => {
    expect(parseUnpushed("a1\nb2\n", false).size).toBe(0);
  });
});
