import { describe, expect, it } from "vitest";
import {
  type LedgerCleanupIO, type LedgerClient, ledgerClients, ledgerCopyCanGo, ledgerHookArguments, ledgerMcpArguments, ledgerRegistration, ledgerStableCommand, ledgerStatusArguments,
  runLedgerCleanup,
} from "@/entities/agent/lib/ledger-cleanup";

// The one-time cleanup after the Ledger's removal: what it asks of the ledger command's copy and of the clients, and
// when the copy may be deleted. (macOS: macos/Tools/test-ledger-cleanup.sh)

const STABLE = "C:/Users/example/AppData/Roaming/Gitrochi/bin/gitrochi-ledger.exe";
const BIN = "C:/Users/example/AppData/Roaming/Gitrochi/bin";
const DATABASE = "C:/Users/example/AppData/Roaming/Gitrochi/ledger/ledger.sqlite3";

/** A fake computer: the copy, what each client still has, and every command that ran */
function fixture(o: { copy?: boolean; clients?: LedgerClient[]; unreadable?: boolean } = {}) {
  const files = new Set<string>([DATABASE, ...(o.copy === false ? [] : [STABLE])]);
  const state: Record<LedgerClient, { hooks: number; mcp: boolean }> = { claude: { hooks: 0, mcp: false }, codex: { hooks: 0, mcp: false } };
  const calls: string[] = [];
  const io: LedgerCleanupIO = {
    exists: async (path) => files.has(path),
    run: async (program, args) => {
      const line = args.join(" ");
      if (program === STABLE) {
        calls.push(`ledger ${line}`);
        const client = ledgerClients.find((c) => args.includes(c));
        if (client && line === ledgerStatusArguments(client).join(" ")) return o.unreadable ? { status: 1, stdout: "" } : { status: 0, stdout: JSON.stringify({ client, ownedHookCount: state[client].hooks, mcp: { registered: state[client].mcp, command: null } }) };
        if (client && line === ledgerHookArguments(client).join(" ")) state[client].hooks = 0;
        return { status: 0, stdout: "" };
      }
      const client = ledgerClients.find((c) => program.endsWith(`${c}.exe`));
      if (!client) return null;
      calls.push(`${client} ${line}`);
      if (line === ledgerMcpArguments(client).join(" ")) state[client].mcp = false;
      return { status: 0, stdout: "" };
    },
    program: (client) => (o.clients?.includes(client) ? `C:/Users/example/.local/bin/${client}.exe` : null),
    list: async (folder) => [...files].filter((path) => path.startsWith(`${folder}/`)).map((path) => path.slice(folder.length + 1)),
    remove: async (path) => {
      calls.push(`remove ${path}`);
      for (const file of [...files]) if (file === path || file.startsWith(`${path}/`)) files.delete(file);
    },
  };
  return { files, state, calls, io };
}

describe("Ledger cleanup pieces", () => {
  it("reads hooks and the MCP server from the ledger command's status", () => {
    const status = '{"action":"status","client":"claude","installed":true,"ownedHookCount":8,"otherHookCount":1,"health":"ok","mcp":{"command":null,"configPath":"C:/Users/example/.claude.json","registered":true}}';
    expect(ledgerRegistration(status)).toEqual({ hooks: 8, mcp: true });
    expect(ledgerRegistration('{"ownedHookCount":0,"mcp":{"registered":false}}')).toEqual({ hooks: 0, mcp: false });
    // a command from before it reported the MCP server
    expect(ledgerRegistration('{"ownedHookCount":2}')).toEqual({ hooks: 2, mcp: false });
    for (const text of ["", "not json", "[]", "null", '{"error":{"code":"INVALID_ARGUMENT","message":"Settings are not valid JSON; nothing was changed"}}']) expect(ledgerRegistration(text)).toBeNull();
  });

  it("asks the copy and each client's own command", () => {
    expect(ledgerStableCommand("C:\\Users\\example\\AppData\\Roaming", true)).toBe(STABLE);
    expect(ledgerStableCommand("/Users/example/Library/Application Support/", false)).toBe("/Users/example/Library/Application Support/Gitrochi/bin/gitrochi-ledger");
    expect(ledgerStatusArguments("codex")).toEqual(["--json", "integrate", "codex", "--status"]);
    expect(ledgerHookArguments("claude")).toEqual(["integrate", "claude", "--remove"]);
    expect(ledgerMcpArguments("claude")).toEqual(["mcp", "remove", "--scope", "user", "gitrochi-ledger"]);
    expect(ledgerMcpArguments("codex")).toEqual(["mcp", "remove", "gitrochi-ledger"]);
  });

  it("lets the copy go only when every client is known to have nothing left", () => {
    const empty = { hooks: 0, mcp: false };
    expect(ledgerCopyCanGo([empty, empty])).toBe(true);
    expect(ledgerCopyCanGo([empty, { hooks: 1, mcp: false }])).toBe(false);
    expect(ledgerCopyCanGo([{ hooks: 0, mcp: true }, empty])).toBe(false);
    expect(ledgerCopyCanGo([empty, null])).toBe(false);
  });
});

describe("Ledger cleanup", () => {
  it("runs nothing without the copy", async () => {
    const f = fixture({ copy: false, clients: ["claude", "codex"] });
    expect(await runLedgerCleanup(STABLE, f.io)).toBe(false);
    expect(f.calls).toEqual([]);
  });

  it("deletes a copy nothing names, with its empty folder, and leaves the database", async () => {
    const f = fixture();
    expect(await runLedgerCleanup(STABLE, f.io)).toBe(true);
    expect(f.calls).toEqual(["ledger --json integrate claude --status", "ledger --json integrate codex --status", "ledger browser-host remove", `remove ${STABLE}`, `remove ${BIN}`]);
    expect([...f.files]).toEqual([DATABASE]);
  });

  it("removes hooks through the copy and the MCP server through the client, then the copy", async () => {
    const f = fixture({ clients: ["claude", "codex"] });
    f.state.claude = { hooks: 8, mcp: true };
    f.state.codex = { hooks: 7, mcp: false };
    expect(await runLedgerCleanup(STABLE, f.io)).toBe(true);
    expect(f.calls).toEqual([
      "ledger --json integrate claude --status", "ledger integrate claude --remove", "claude mcp remove --scope user gitrochi-ledger", "ledger --json integrate claude --status",
      "ledger --json integrate codex --status", "ledger integrate codex --remove", "ledger --json integrate codex --status",
      "ledger browser-host remove", `remove ${STABLE}`, `remove ${BIN}`,
    ]);
    expect([...f.files]).toEqual([DATABASE]);
  });

  it("keeps the copy while a client's MCP server could not be removed, and finishes at a later start", async () => {
    const f = fixture();
    f.state.codex = { hooks: 7, mcp: true };
    expect(await runLedgerCleanup(STABLE, f.io)).toBe(false);
    expect(f.files.has(STABLE)).toBe(true);
    expect(f.state.codex).toEqual({ hooks: 0, mcp: true });
    f.io.program = (client) => `C:/Users/example/.local/bin/${client}.exe`;
    expect(await runLedgerCleanup(STABLE, f.io)).toBe(true);
    expect(f.files.has(STABLE)).toBe(false);
    // hooks already gone are not removed again
    expect(f.calls.filter((call) => call === "ledger integrate codex --remove")).toHaveLength(1);
  });

  it("removes nothing when the status cannot be read", async () => {
    const f = fixture({ clients: ["claude", "codex"], unreadable: true });
    f.state.claude = { hooks: 8, mcp: true };
    expect(await runLedgerCleanup(STABLE, f.io)).toBe(false);
    expect(f.files.has(STABLE)).toBe(true);
    expect(f.calls.some((call) => call.includes("--remove") || call.includes("mcp remove") || call.startsWith("remove "))).toBe(false);
  });

  it("leaves the folder when it holds anything else", async () => {
    const f = fixture();
    f.files.add(`${BIN}/other-tool.exe`);
    expect(await runLedgerCleanup(STABLE, f.io)).toBe(true);
    expect([...f.files].sort()).toEqual([`${BIN}/other-tool.exe`, DATABASE].sort());
  });
});
