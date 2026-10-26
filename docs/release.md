# Releases

Maintainers only. Only maintainers can create `v*` tags, and the update signing keys (`GITROCHI_UPDATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY`) live in the `release` environment, which only `v*` tags and `main` can use, so a pull request's workflow run cannot read them. Since `main` changes only through pull requests, the version bump is a pull request too, and the tag follows the merge.

The version is set in `CFBundleShortVersionString` in `macos/Resources/Info.plist`, `GITSW_VERSION` in `tools/gitch/gitch`, and on Windows in `package.json`, `package-lock.json`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml` and the gitrochi package in `Cargo.lock` — all together. `CFBundleVersion` is a separate build number. The CLI's `GITCH_VERSION_SCHEME="gitrochi"` marks the version as the app's rather than the old standalone one, and graph support is announced through `GITCH_GRAPH_API`. After changing the version, `bash tools/check-versions.sh` must pass.

```sh
git switch -c release/0.3.12            # bump the version (Info.plist · tauri.conf.json · package.json …)
git commit -m "Release 0.3.12 (summary)"
git push -u origin HEAD && gh pr create --fill && gh pr merge --auto --merge
# once merged
git switch main && git pull --ff-only
git tag v0.3.12 && git push origin v0.3.12   # the tag run uploads the signed files to a draft release
```

Release builders also need the shared Rust core: the macOS workflow installs both Apple targets, and the Windows workflow installs `wasm32-unknown-unknown`. Native `gitch-core`, the local MCP entry point and required third-party notices are packaged with the app. Generated WASM and native binaries are built from the locked source; they are not committed. See [the core build notes](../crates/README.md).

The tag run is two workflows, macOS (`.github/workflows/macos.yml`) and Windows (`.github/workflows/windows.yml`), and each stops if the tag does not match the app version (`Info.plist`, `tauri.conf.json`). Both upload to the release for that tag; whichever uploads first creates the draft. The two upload jobs share one `concurrency` group and run one at a time, so there is never a second draft.

- macOS: `Gitrochi-0.3.12-macOS.dmg`, `.zip`, `.zip.sig`, `.sha256`, plus the standalone `gitch` and `gitch.sha256` (what `tools/gitch/install.sh` and `gitch self-update` download)
- Windows (after the self-test passes): `Gitrochi_0.3.12_x64-setup.exe`, `.exe.sig`, `_x64_portable.zip` (`Gitrochi.exe`, `LICENSE.txt`, `THIRD_PARTY_NOTICES.md`, bundled gitch helpers, `gitrochi-mcp.mjs` and `gitch-core.exe`), `_windows.sha256`, `latest.json`. The same files stay in that run's `gitrochi-windows` artifact.

The apps' update check ignores drafts, so before publishing:

1. Write the release notes. The macOS app's update window shows this text.
2. Put the one line the Windows update window shows into `notes` in `latest.json`. The tag run uploads it empty (an empty note shows just the version), and rerunning the Windows "upload to release" job empties it again, so do this right before publishing.

   ```sh
   gh release download v0.3.12 -R Gitrochi/Gitrochi -p latest.json   # edit "notes" in the downloaded file, then
   gh release upload v0.3.12 latest.json -R Gitrochi/Gitrochi --clobber
   ```

3. Publish: `gh release edit v0.3.12 -R Gitrochi/Gitrochi --draft=false --latest`
