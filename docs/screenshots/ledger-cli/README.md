# Ledger command line

Real `gitrochi-ledger` output captured from macOS pseudo-terminals, then rendered with the app's xterm terminal renderer. These are terminal previews, not a Windows desktop verification.

- [80 columns, dark](ledger-cli-80-dark.png)
- [80 columns, light](ledger-cli-80-light.png)
- [28 columns, dark](ledger-cli-28-dark.png)
- [40 columns, no colour](ledger-cli-40-no-color.png)

The regression tests cover 28, 40, 80 and 120 columns, light and dark backgrounds, no colour, plain output, mixed terminal/pipe output, JSON, MCP and hooks. The eye rows match `LOGO_S` in `tools/gitch/gitch`; no terminal mode, cursor or screen is changed.
