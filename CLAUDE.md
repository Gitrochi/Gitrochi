# Claude Code

@AGENTS.md

Notes for Claude Code specifically:

- Reply in the language the maintainer writes in (usually Korean). Everything that goes into the repository — code, comments, commit messages, pull requests, docs — is English.
- The maintainer often runs Claude Code inside the installed Gitrochi app's terminal. Never `macos/build.sh install`, relaunch or quit the app from such a session; build only, and tell the maintainer to install when it suits them.
- Terminal-panel problems reported from inside the app (keys, focus, pasting) are usually Gitrochi bugs, not Claude Code configuration.
- After every change, run the verification in AGENTS.md step 6 and report exactly what passed, what you skipped, and why.
