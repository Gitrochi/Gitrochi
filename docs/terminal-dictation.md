# macOS voice workspace

The macOS terminal reuses Gitrochi's icon, a monospace wordmark and restrained
system-color controls. Its shortcut rail prepares Status, Preflight, Pull
request and CI commands; Return runs them. New terminal keeps the current
folder, the status bar copies its full path with confirmation, and new-output
badges select a terminal with unseen output. Narrow panes collapse controls;
short panes preserve output space by hiding the shortcut rail.

## 1. Hold to talk and recognition hints

Open Voice input from the terminal microphone or the app menu. With a repository
open, hold **Control-Shift-Space**, speak and release to review. The local monitor
works only in the owning Gitrochi window and its voice sheet. It does not register
a global shortcut or request Accessibility access. Repeats are ignored; releasing
Space finalizes even if the modifiers were released first. Escape, another
window or app becoming active, minimization and closure stop an active hold.
The chord leaves Control-Option-Space available for input-source switching.

Initial microphone and speech permissions are granted using Start listening;
setup never starts audio. The next explicit start or hold records. Apple
on-device recognition and the selected language's installed speech assets are
required. There is no cloud-speech fallback. Errors offer user-initiated links
to the relevant Microphone, Speech Recognition, Keyboard or Sound settings.

Automatic language follows an explicitly chosen app language, otherwise the
preferred system language. Korean maps to ko-KR and English to en-US; an explicit
selection wins. Recognition hints combine safe repository filenames, branch
names, common tool names and editable custom terms. Korean is normalized to NFC,
duplicates are removed, and hints are bounded to 100 entries of 80 characters.
Private filenames, absolute paths, URLs and likely credentials are excluded.
Hints help spelling; they never substitute or execute commands. They can be
turned off or edited in the voice sheet and Settings > CLI.

Manual Start/Stop and editable text remain available alongside the hold shortcut.
Switching apps stops audio but keeps a reviewed draft in memory while its sheet
is open. Closing the sheet, switching its terminal/repository or closing the
repository discards that ephemeral draft. No audio file or dictation history is
saved by the speech service.

## 2. Optional AI cleanup

Clean up sends only the current text, enabled word hints and language hint to
the default provider configured in Settings > AI. The provider is shown before
sending. No provider is configured or contacted automatically. Cleanup uses the
existing text-generation boundary without applying user-defined global rules
that might turn dictated instructions into actions.

The AI receives a strict JSON-only transcription task. The response is validated
before review: text must remain bounded, identifiers, paths, commands, numbers
and negation must be preserved, and invalid or excessive rewrites are rejected.
The original and cleaned text remain separate. Use cleaned text is explicit,
and Restore original remains available afterwards. Edits, changed provider
configuration, recording again or cancellation invalidate old suggestions and
late results. Cleanup never submits terminal input or launches a task.

## 3. Reviewed destinations

A draft has four destinations:

| Destination | Result after explicit confirmation |
| --- | --- |
| Terminal | Inserts a sanitized single line into the captured terminal. It never presses Return. |
| Explain changes | Uses the existing frozen change-question snapshot and explanation provider, then opens its answer sheet. |
| Commit draft | Uses staged changes and voice guidance to fill the commit message editor. It does not stage, commit or push. |
| Ask agent | Starts the selected existing agent inside Gitrochi: Claude uses normal approval, Codex read-only, Gemini plan mode. |

Non-terminal destinations show the repository, reviewed request, provider or
agent and action before sending. The opened repository, terminal identity,
working folder, HEAD, selected changes and relevant AI configuration are checked
before dispatch. Commit drafting additionally verifies the staged snapshot and
keeps any commit-message edits made while generation runs. Cancelling or a newer
workflow invalidates late results. Refresh repository context reloads current
repository data before capturing a new context.

Explicit AI destinations send the reviewed text and scoped change context to the
chosen provider. Ask agent passes the reviewed task to the existing session
manager, which keeps its normal local task metadata, and to that agent's CLI.
These deliberate destinations are distinct from the ephemeral speech draft;
there is no new transcript-history or credential store.

## Attribution and scope

This native SwiftUI implementation adapts the dictation workflow in
[Atticus](https://github.com/SaarthurR/atticus-mac). It does not bundle or launch
Atticus.swift or atticus.py. Gitrochi continues to target macOS 15 and uses
SFSpeechRecognizer rather than requiring SpeechAnalyzer on macOS 26. The full
Copyright (c) 2026 SaarthurR MIT notice is retained in THIRD_PARTY_NOTICES.md and
included by the existing app packaging step. Windows does not expose this
integration, as requested.

The three implemented layers are app-local hold/vocabulary, optional cleanup
with original comparison, and explicit destinations using Gitrochi's existing
AI/agent features. Whisper downloads/runtime, automatic speech-language
detection, other-app dictation, wake words, personal memory, screen automation,
Meeting Copilot, voice-created watchers and routines remain outside this change.

Visual reference: https://x.ai/news/grok-build-cli . The terminal uses Gitrochi's
own artwork and native components; no Grok code or branding is included.

## Verification

- `bash macos/Tools/test-terminal-input.sh`: insertion and dictation generation.
- `bash macos/Tools/test-terminal-voice.sh`: Korean vocabulary, locale selection,
  privacy filters and hold state transitions.
- `bash macos/Tools/test-terminal-hold.sh`: actual app-local key-event handling;
  needs WindowServer access, returns 77 when unavailable, never records audio.
- `bash macos/Tools/test-terminal-cleanup.sh`: injected AI contract, Korean
  meaning/identifier preservation, cancellation and stale replies.
- `bash macos/Tools/test-terminal-voice-action.sh`: production routing with inert
  Git/AI/agent boundaries, stale context and commit-draft preservation.
- `bash macos/Tools/test-terminal-layout.sh <output-folder>`: production UI,
  Korean/light/dark layouts and inert button interactions.
- `bash macos/build.sh`: complete app build without installation or restart.

A live microphone/permission round trip and recognition accuracy still need
manual checks with installed speech assets. No automated test grants access,
records speech, contacts a real AI provider, starts a real agent or runs a commit.
