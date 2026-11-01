export type LedgerClient = "claude" | "codex";

/** Commands to copy into the host's shell; registration and passive activity hooks are independent. */
export function ledgerSetup(client: LedgerClient, binary: string, windows = false) {
  const quote = (value: string) => windows ? `'${value.replace(/'/g, "''")}'` : `'${value.replace(/'/g, "'\\''")}'`;
  const run = `${windows ? "& " : ""}${quote(binary)}`;
  return {
    register: `${client} mcp add ${client === "claude" ? "--scope user " : ""}gitrochi-ledger -- ${quote(binary)} mcp`,
    install: `${run} integrate ${client} --install`,
    status: `${run} integrate ${client} --status`,
    remove: `${run} integrate ${client} --remove`,
    config: client === "codex"
      ? `[mcp_servers.gitrochi-ledger]\ncommand = ${JSON.stringify(binary)}\nargs = ["mcp"]`
      : JSON.stringify({ mcpServers: { "gitrochi-ledger": { command: binary, args: ["mcp"] } } }, null, 2),
  };
}
