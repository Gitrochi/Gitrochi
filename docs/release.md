# Releases

Maintainers only. Only maintainers can create `v*` tags, and the update signing keys (`GITROCHI_UPDATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY`) live in the `release` environment, which only `v*` tags and `main` can use, so a pull request's workflow run cannot read them. Since `main` changes only through pull requests, the version bump is a pull request too, and the tag follows the merge.

The version is set in `CFBundleShortVersionString` in `macos/Resources/Info.plist`, `GITSW_VERSION` in `tools/gitch/gitch` with the current version and the sample graph output in `tools/gitch/README.md`, and on Windows in `package.json`, `package-lock.json`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml` and the gitrochi package in `Cargo.lock`, and for the flow engine in `tools/gitch-flow/Cargo.toml` and the gitch-flow package in its `Cargo.lock` — all together. `CFBundleVersion` is a separate build number. The CLI's `GITCH_VERSION_SCHEME="gitrochi"` marks the version as the app's rather than the old standalone one, and graph support is announced through `GITCH_GRAPH_API`. After changing the version, `bash tools/check-versions.sh` must pass.

```sh
git switch -c release/0.3.12            # bump the version (Info.plist · tauri.conf.json · package.json …)
git commit -m "Release 0.3.12 (summary)"
git push -u origin HEAD && gh pr create --fill && gh pr merge --auto --merge
# once merged
git switch main && git pull --ff-only
git tag v0.3.12 && git push origin v0.3.12   # the tag run uploads the signed files to a draft release
```

Release builders also need the shared Rust core: the macOS workflow installs both Apple targets, and the Windows workflow installs `wasm32-unknown-unknown`. Native `gitch-core`, the local MCP entry point and required third-party notices are packaged with the app. Generated WASM and native binaries are built from the locked source; they are not committed. See [the core build notes](../crates/README.md).

The flow engine's versioned dependency notices are generated from its locked normal/build graph for all platforms. After changing its version or dependencies, run `python3 tools/gitch-flow/ci/generate-notices.py`; `--check` verifies the committed result without rewriting it. The Linux static PR job checks regeneration, builds the same musl target used for release, runs its `version` command directly, rejects ELF interpreters/shared-library dependencies, and checks its checksum. Tag uploads repeat the Linux asset validation. Both app packages include `gitch-flow-THIRD-PARTY-NOTICES.txt`; all three workflows publish that same notice file and its `.sha256` beside the standalone engines.

The tag run is three workflows, macOS (`.github/workflows/macos.yml`), Windows (`.github/workflows/windows.yml`) and Flow engine (`.github/workflows/flow.yml`, the Linux engine), and each stops if the tag does not match its version (`Info.plist`, `tauri.conf.json`, `tools/gitch-flow/Cargo.toml`). All three upload to the release for that tag; whichever uploads first creates the draft. The upload jobs share one `concurrency` group with `queue: max` and run one at a time, retaining all three upload jobs while preventing a second draft.

- macOS: `Gitrochi-0.3.12-macOS.dmg`, `.zip`, `.zip.sig`, `.sha256`, plus the standalone `gitch` and `gitch.sha256` (what `tools/gitch/install.sh` and `gitch self-update` download) and the universal flow engine `gitch-flow-macos` and `.sha256`
- Windows (after the self-test passes): `Gitrochi_0.3.12_x64-setup.exe`, `.exe.sig`, `_x64_portable.zip` (`Gitrochi.exe`, `LICENSE.txt`, `THIRD_PARTY_NOTICES.md`, `gitch-flow-THIRD-PARTY-NOTICES.txt`, bundled gitch helpers, `gitrochi-mcp.mjs`, `gitch-core.exe` and `gitch-flow.exe`), `_windows.sha256`, `latest.json`, and the flow engine `gitch-flow-windows-x64.exe` and `.sha256`. The same files stay in that run's `gitrochi-windows` artifact.
- Linux (Flow engine workflow): the statically linked flow engine `gitch-flow-linux-x64` and `.sha256`, for CLI-only users
- Shared standalone notices: `gitch-flow-THIRD-PARTY-NOTICES.txt` and `.sha256` (identical bytes from all three workflows). With the three gitch script/checksum pairs, a signed release has 23 unique assets.

The apps' update check ignores drafts, so before publishing:

1. Write the release notes. The macOS app's update window shows this text.
2. Put the one line the Windows update window shows into `notes` in `latest.json`. The tag run uploads it empty (an empty note shows just the version), and rerunning the Windows "upload to release" job empties it again, so do this right before publishing.

   ```sh
   gh release download v0.3.12 -R Gitrochi/Gitrochi -p latest.json   # edit "notes" in the downloaded file, then
   gh release upload v0.3.12 latest.json -R Gitrochi/Gitrochi --clobber
   ```

3. Publish: `gh release edit v0.3.12 -R Gitrochi/Gitrochi --draft=false --latest`

## Betas

A beta lets people who opted in try the next version before everyone gets it. Its version adds a pre-release part to the coming release's: `0.4.2-beta.1`, `0.4.2-beta.2`, then the release `0.4.2`. Versions are ordered as semver, so `0.4.2-beta.1 < 0.4.2-beta.2 < 0.4.2`, and a beta user is offered the release when it comes out. The same rules are in `ReleaseVersion` (macOS updater), `shared/platform/release-version.ts` (Windows) and `ver_lt` (gitch).

Cut a beta like a release, with the beta version in every file listed above (`bash tools/check-versions.sh` accepts `0.4.2-beta.1`):

```sh
git switch -c release/0.4.2-beta.1      # set 0.4.2-beta.1 everywhere
git commit -m "Release 0.4.2-beta.1 (summary)"
git push -u origin HEAD && gh pr create --fill && gh pr merge --auto --merge
# once merged
git switch main && git pull --ff-only
git tag v0.4.2-beta.1 && git push origin v0.4.2-beta.1
```

The tag run creates the draft as a **pre-release** (every tag with a `-` part). Write the notes and `latest.json` as for a release, then publish it as a pre-release, never as latest:

```sh
gh release edit v0.4.2-beta.1 -R Gitrochi/Gitrochi --draft=false --prerelease --latest=false
```

Who gets it:

- Settings › Update has "Receive beta updates", off by default. With it on, the update check also looks at pre-releases: macOS picks the newest release with a macOS zip, Windows reads `latest.json` from the newest release that has one. Turning it off keeps the beta until the next release, which is newer.
- Everyone else is unaffected: the macOS check skips pre-releases, Windows reads `releases/latest/download/latest.json` (GitHub's latest is never a pre-release), and `gitch self-update` and `tools/gitch/install.sh` skip pre-releases.
