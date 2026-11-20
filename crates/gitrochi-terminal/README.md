# Terminal host

`gitrochi-terminal-host` owns the pseudo terminals of the Gitrochi apps, so shells and agents keep running after the app quits, and a relaunched app reattaches to them with their recent output. Issue #420 tracks the whole change; this crate is its first step, and neither app uses it yet.

```sh
gitrochi-terminal-host --state-dir <app state folder> [--idle-exit <seconds>]
```

The app starts the host when none answers, detached from itself (its own process group or session on macOS, `DETACHED_PROCESS` on Windows) so quitting the app does not end it. A host that finds another one answering for the same folder exits with code 3. The host ends by itself once no app has been connected and nothing has run for `--idle-exit` seconds (30 by default).

## Finding the host

The host writes `terminal-host.json` into the state folder, readable by the user only:

```json
{ "version": 1, "pid": 4242, "name": "<socket path or pipe name>", "token": "<64 hex digits>" }
```

`name` is a Unix socket in a new private folder under the temporary directory (macOS, Linux), or a named pipe `gitrochi-terminal-<random>` (Windows). It is random for each host, so it cannot be taken in advance, and a connection that does not open with the file's token is refused. The file is removed when the host ends.

## Frames

Every frame is a little-endian `u32` length of the rest, then a kind byte, then the payload. Frames over 16 MiB are refused.

| Kind | Payload |
|---|---|
| `0` control | one JSON message, tagged by `type` |
| `1` data | little-endian `u16` session id length, the id in UTF-8, then raw terminal bytes: output from the host, input from the app |

## Messages

The first frame from the app is `{"type":"hello","version":1,"token":"…"}`; the host answers `welcome` (with its `pid`) or `error` and closes. After that, each request is answered by one reply, in order; input (data frames) and `bye` are not answered.

| Request | Reply |
|---|---|
| `list` | `sessions` — every session, oldest first, ended ones until forgotten |
| `spawn` `{spec}` | `spawned` `{id, pid}` |
| `attach` `{id}` | `attached` `{session}`, then the scrollback as one data frame, then live output |
| `detach` `{id}` | `ok` |
| `resize` `{id, cols, rows}` | `ok` |
| `kill` `{id}` | `ok` |
| `forget` `{id}` | `ok`; refused while the session runs |
| `bye` | none; the host closes the connection, sessions keep running |

Any request may be answered by `error` `{message}` instead. Unasked, the host sends `exited` `{id, exit_code}` to every app attached to a session whose program ended.

A `spec` is `{id, program, args, cwd, env, cols, rows, meta}`. `program` is a path or a name on the host's `PATH`; `env` is added to the host's own environment; `meta` is the app's own JSON (repository, tab title, how to restore the tab), kept and listed back as given.

## Limits of this version

- The scrollback is the last 4 MiB of raw output. Once it is trimmed the replay starts on a line break, but a full-screen program may need a resize to redraw.
- An app that stops reading falls behind by at most 4096 frames; then the host stops sending to it and closes the connection at its next request.
- Sessions do not survive a reboot or the end of the host.
- Ending the shell ends what the shell's process group gets on hangup; programs that detached from it keep running, as in any terminal.
