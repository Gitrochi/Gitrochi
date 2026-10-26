## What and why

<!-- What changed and why. Related issue: Closes #123 -->

## Screenshots

<!-- If a screen changed: light and dark screenshots (demo repository: docs/make-demo-repo.sh). Hide company and personal details. -->

## Checklist

- [ ] macOS: `macos/build.sh` builds with no errors or warnings
- [ ] Windows: `npx tsc --noEmit -p .` · `npx vitest run` · `cargo check` pass
- [ ] Both platforms (if one only, why: )
- [ ] New behaviour has a unit test or a `windows/src/app/selftest.ts` step
- [ ] Checked in the light and the dark theme
- [ ] No tokens or company details in code, logs or screenshots
- [ ] Follows the [code style](../docs/code-style.md) and the [Git workflow](../docs/git-workflow.md) (branch name, `Area: Summary` commit messages in English, one topic per commit)
