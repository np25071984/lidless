# lidless

Keeps the built-in MacBook display dark while an external display is connected, run as a launchd service. One Swift package, no dependencies.

```bash
swift test                     # the decision logic
./build.sh                     # release build into build/lidless
./build.sh --install           # install to ~/.local/bin and restart the service
lidless status | logs          # the running service
```

## Where things are written down

Each fact lives in one place. `CLAUDE.md` only imports this file; edit this one.

| What | Where |
|---|---|
| Decision logic: what to do with the panel on each check, the saved level, the launchd file, Homebrew detection | a test in `Tests/lidlessTests`, named after the rule and its reason |
| How macOS behaves, and why the code is shaped around it | comments at the code that depends on it, and *How it works* in `README.md` |
| How to use lidless | `README.md` |
| What changed in a release | the Changelog in `README.md` |
| The project page, np25071984.github.io/lidless | `docs/index.html`: a short pitch that links to `README.md` for details. Change it when a headline feature, the install commands or the known limitation change |

## Rules

- **A behaviour change comes with a test.** Keep decisions in the pure types (`Policy`, `SavedLevel`, the static functions on `Service`), not in the code that calls macOS, so they can be tested without displays.
- **Constants are named.** A number that matters gets a `static let` with a comment on why it has that value, on the type that owns it.
- **No history in the docs** outside the Changelog.
- **Install by rename**, never by overwriting the binary in place.
- **Check on the real desktop** what tests cannot: after a change to docking, wake or brightness handling, `./build.sh --install` and plug a display in and out, or ask the user to.

## Releasing

Bump `version` in `Sources/Lidless/Support.swift`, add a dated Changelog entry to `README.md`, and say what an upgrading user has to do, if anything.

Once the release PR is merged, tag its merge commit and push the tag:

```bash
git tag -a vX.Y.Z <merge commit> -m "lidless X.Y.Z: <one line>"
git push origin vX.Y.Z
```

The tag runs `.github/workflows/release.yml`, which tests, builds the universal binary and publishes `lidless-macos.tar.gz` and its `.sha256` as the release `install.sh` installs. It fails, publishing nothing, if `version` does not match the tag or the Changelog has no entry for it.

Then update `Formula/lidless.rb` in a PR: `url` to the new tag (Homebrew reads the version from it), `sha256` to the one in the release's `lidless-macos.tar.gz.sha256`. Homebrew users get the release only once that is merged.
