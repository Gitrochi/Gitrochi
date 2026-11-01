import { describe, expect, it } from "vitest";
import { ledgerSetup } from "../src/features/connect-ledger-mcp/lib/setup";

describe("Ledger client setup", () => {
  it("keeps MCP registration separate from passive hooks for each client", () => {
    const claude = ledgerSetup("claude", "/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger");
    const codex = ledgerSetup("codex", "/Applications/Gitrochi.app/Contents/MacOS/gitrochi-ledger");
    expect(claude.register).toContain("claude mcp add --scope user gitrochi-ledger -- ");
    expect(codex.register).toContain("codex mcp add gitrochi-ledger -- ");
    expect(codex.install).toContain(" integrate codex --install");
    expect(codex.status).toContain(" integrate codex --status");
    expect(codex.remove).toContain(" integrate codex --remove");
    expect(JSON.parse(claude.config).mcpServers["gitrochi-ledger"].args).toEqual(["mcp"]);
    expect(codex.config).toContain("[mcp_servers.gitrochi-ledger]\ncommand = ");
    expect(codex.config).not.toContain("mcpServers");
  });

  it("copies status without removing tracking, for either client or shell", () => {
    for (const client of ["claude", "codex"] as const) {
      for (const windows of [false, true]) {
        const setup = ledgerSetup(client, "/Tools/gitrochi-ledger", windows);
        expect(setup.status).not.toMatch(/--remove|\n/);
        expect(setup.remove).not.toMatch(/--status|\n/);
      }
    }
  });

  it("quotes spaces, apostrophes and shell expansion characters as literal paths", () => {
    const posix = ledgerSetup("codex", "/Applications/Team's $Tools/Gitrochi");
    expect(posix.register).toContain("'/Applications/Team'\\''s $Tools/Gitrochi'");
    const windows = ledgerSetup("codex", "C:\\Team's $Tools\\gitrochi-ledger.exe", true);
    expect(windows.install).toBe("& 'C:\\Team''s $Tools\\gitrochi-ledger.exe' integrate codex --install");
    expect(windows.register).toBe("codex mcp add gitrochi-ledger -- 'C:\\Team''s $Tools\\gitrochi-ledger.exe' mcp");
    const encoded = windows.config.split("\n")[1].slice("command = ".length);
    expect(JSON.parse(encoded)).toBe("C:\\Team's $Tools\\gitrochi-ledger.exe");
  });
});
