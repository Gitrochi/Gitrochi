import { describe, expect, it } from "vitest";
import { type FlowCreationDraft, flowCreationDocument, flowCreationFile, flowCreationProblem } from "../src/entities/flow/model/creation";

const draft = (patch: Partial<FlowCreationDraft> = {}): FlowCreationDraft => ({
  name: "verify",
  description: "",
  parallel: false,
  steps: [{ title: "Check", command: "npm test" }],
  ...patch,
});

interface CreatedFlow {
  description?: string;
  trigger: string[];
  nodes: Record<string, { description?: string; run: string; needs?: string[] }>;
}
const roundTrip = (value: FlowCreationDraft) => JSON.parse(JSON.stringify(flowCreationDocument(value))) as { version: number; flows: Record<string, CreatedFlow> };

describe("guided flow creation", () => {
  it("accepts portable names and rejects missing, invalid, and overlong names", () => {
    expect(flowCreationProblem(draft({ name: " \n " }), [])).toBe("name-required");
    for (const name of ["Verify", "1verify", "verify checks", "../verify", "__proto__", "a".repeat(65)]) {
      expect(flowCreationProblem(draft({ name }), [])).toBe("name-invalid");
    }
    for (const name of ["verify", "test_build-2", "a".repeat(64), " verify "]) {
      expect(flowCreationProblem(draft({ name }), [])).toBeNull();
    }
  });

  it("rejects existing flow names without depending on letter case", () => {
    expect(flowCreationProblem(draft(), ["deploy", "VERIFY"])).toBe("name-exists");
    expect(flowCreationProblem(draft({ name: " verify " }), ["verify"])).toBe("name-exists");
    expect(flowCreationProblem(draft(), ["verify-more"])).toBeNull();
  });

  it("requires at least one step and a nonblank command for every step", () => {
    expect(flowCreationProblem(draft({ steps: [] }), [])).toBe("steps-required");
    expect(flowCreationProblem(draft({ steps: [{ title: "Check", command: "npm test" }, { title: "", command: " \n\t " }] }), [])).toBe("command-required");
    expect(flowCreationProblem(draft({ steps: [{ title: "", command: " npm test\n" }] }), [])).toBeNull();
  });

  it("rebuilds sequential dependencies from the current step order", () => {
    const steps = [
      { title: "Install", command: "npm ci" },
      { title: "Check", command: "npm test" },
      { title: "Build", command: "npm run build" },
    ];
    const original = roundTrip(draft({ steps })).flows.verify;
    expect(Object.values(original.nodes).map((node) => node.run)).toEqual(["npm ci", "npm test", "npm run build"]);
    expect(original.nodes["step-1"].needs).toBeUndefined();
    expect(original.nodes["step-2"].needs).toEqual(["step-1"]);
    expect(original.nodes["step-3"].needs).toEqual(["step-2"]);

    const reordered = roundTrip(draft({ steps: [steps[0], steps[2], steps[1]] })).flows.verify;
    expect(reordered.nodes["step-2"].run).toBe("npm run build");
    expect(reordered.nodes["step-3"].run).toBe("npm test");
    expect(reordered.nodes["step-3"].needs).toEqual(["step-2"]);
    expect(steps[1].command).toBe("npm test");
  });

  it("makes every parallel step independent even when titles are repeated", () => {
    const flow = roundTrip(draft({ parallel: true, steps: [
      { title: "Check", command: "npm test" },
      { title: "Check", command: "npm run lint" },
    ] })).flows.verify;
    expect(Object.keys(flow.nodes)).toEqual(["step-1", "step-2"]);
    expect(Object.values(flow.nodes).every((node) => !Object.hasOwn(node, "needs"))).toBe(true);
  });

  it("preserves quoted multiline commands, interpolation, and surrounding whitespace verbatim", () => {
    const command = "  printf '%s\\n' \"${BUILD_MODE}\"\nnode -e 'console.log(\"ready: #1\")'\n  ";
    const value = draft({ name: " verify ", description: "  Project checks  ", steps: [{ title: "  Run checks  ", command }] });
    expect(flowCreationProblem(value, [])).toBeNull();
    const document = roundTrip(value);
    expect(document.version).toBe(1);
    expect(document.flows.verify).toMatchObject({ description: "Project checks", trigger: ["manual"] });
    expect(document.flows.verify.nodes["step-1"]).toEqual({ description: "Run checks", run: command });
    expect(flowCreationFile(value.name)).toBe(".gitch/flows/verify.yml");
  });

  it("omits optional blank metadata instead of manufacturing labels", () => {
    const flow = roundTrip(draft({ description: " \n", steps: [{ title: " \t ", command: "npm test" }] })).flows.verify;
    expect(Object.hasOwn(flow, "description")).toBe(false);
    expect(flow.nodes["step-1"]).toEqual({ run: "npm test" });
  });

  it("retains valid object-like names as ordinary own keys", () => {
    const value = draft({ name: "constructor" });
    expect(flowCreationProblem(value, [])).toBeNull();
    const flows = roundTrip(value).flows;
    expect(Object.hasOwn(flows, "constructor")).toBe(true);
    expect(flows.constructor).toMatchObject({ trigger: ["manual"], nodes: { "step-1": { run: "npm test" } } });
  });
});
