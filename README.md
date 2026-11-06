# lidless

[![CI](https://github.com/np25071984/lidless/actions/workflows/ci.yml/badge.svg)](https://github.com/np25071984/lidless/actions/workflows/ci.yml)

Turns the built-in MacBook display off whenever an external monitor is connected, and restores its previous brightness when you unplug — clamshell-mode behaviour without closing the lid.

A single small binary run as a launchd service: no app, no Dock icon, no menu bar, and no privacy permission to grant. You control it with `lidless start | stop | status | …`.

## What macOS gets wrong

**Nothing turns the built-in screen off for you.** macOS has no option to switch off the built-in display when an external monitor is connected. The only automatic way is to close the lid.

**Turning it off by hand is a chore.** It takes several presses of the brightness key, or a drag of the brightness slider all the way down: a routine nobody asked for, every time you dock.

**It doesn't last.** After the Mac wakes from sleep, macOS lights the built-in screen again, and you do it all over.

## Install

Needs macOS 13 or later, on Apple Silicon or Intel. In Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/np25071984/lidless/main/install.sh | sh
```

This downloads the latest release, checks its checksum, installs `~/.local/bin/lidless` and starts the service. From then on it starts at every login, and launchd restarts it if it crashes.

**Upgrade** by running the same command again. **Remove** it with `lidless uninstall`: it stops the service, relights the panel, and removes the binary, its launchd file, its log and the saved brightness.

To install a particular release, or somewhere other than `~/.local`, set `LIDLESS_VERSION=v0.2.0` or `LIDLESS_PREFIX=/opt/lidless` for `sh`, after the `|`.

Releases from 0.2.1 on carry a build provenance attestation, which proves the tarball was built by this repository's release workflow. Check a downloaded one with `gh attestation verify lidless-macos.tar.gz --repo np25071984/lidless`.

### With Homebrew

```bash
brew trust --tap https://github.com/np25071984/lidless
brew tap np25071984/lidless https://github.com/np25071984/lidless
brew install lidless
brew services start lidless
```

The two-argument `brew tap` points at this repository directly, so the formula lives alongside the source instead of in a separate `homebrew-*` tap.

The `brew trust` step is not optional. Current Homebrew refuses to load formulae from third-party taps until they are trusted, and the failure is reported as `Error: Cannot tap ...: invalid syntax in tap!`, which is misleading — there is nothing wrong with the formula. Trust is matched against the tap's **remote URL**, so the URL form above is what matches.

Upgrade with `brew upgrade lidless && brew services restart lidless`: Homebrew does not restart a running service on upgrade. Remove with `brew services stop lidless && brew uninstall lidless && rm -f ~/.local/state/lidless-brightness`.

Use either Homebrew or the installer, not both: two copies would fight over the backlight. To switch from the installer, run `lidless uninstall` first.

### Building from source

Needs the Xcode command line tools.

```bash
./build.sh                                   # build build/lidless
./build.sh --install                         # also install ~/.local/bin/lidless and restart the service
./build.sh --install --prefix /opt/lidless   # /opt/lidless/bin/lidless
./build.sh --universal                       # Apple Silicon and Intel in one binary, as releases are
swift test                                   # the decision logic
```

## Commands

| Command | |
|---|---|
| `lidless start` | start the service, writing its launchd file if it is missing or points at another binary |
| `lidless stop` | stop it and relight the panel; it starts again at the next login |
| `lidless restart` | restart it |
| `lidless status` | launchd state, pid, log, docking state, the brightness to restore, and every online display. Exits 0 when running, 3 when not. |
| `lidless logs` | follow the service's log |
| `lidless once` | apply the right state now, without the service |
| `lidless off` | switch the built-in display off |
| `lidless on` | switch it back on, at the remembered brightness |
| `lidless run` | the service in the foreground; what launchd runs |
| `lidless uninstall` | stop the service and remove lidless |
| `lidless version` | |

`launchctl` sees the service like any other agent:

```bash
launchctl print gui/$UID/io.github.np25071984.lidless
launchctl kickstart -k gui/$UID/io.github.np25071984.lidless
```

Installed with Homebrew, the service belongs to `brew services` (label `sh.brew.lidless`). `lidless start`, `stop` and `restart` then hand over to `brew services`, so the two never disagree.

The log is `~/Library/Logs/lidless.log`, or `$(brew --prefix)/var/log/lidless.log` under `brew services`; `lidless status` shows which. The brightness to restore on undock is remembered in `~/.local/state/lidless-brightness`.

## How it works

Brightness is driven through `DisplayServicesSetBrightness` from the private `DisplayServices` framework, resolved at runtime with `dlsym` — on Apple Silicon that is the only way to control the built-in panel's backlight. Setting it to `0.0` switches the backlight off; that is the same value macOS itself parks the panel at when the lid is shut.

Two details that are easy to get wrong:

- **The built-in panel is found via `CGGetOnlineDisplayList`, not `CGGetActiveDisplayList`.** With the lid shut or while mirroring, it drops out of the active list while still being the display whose backlight matters.
- **Docking state is polled every 2 seconds rather than driven by `CGDisplayRegisterReconfigurationCallback`.** That callback is not delivered to a background launchd agent, which fails silently — the process stays alive with an empty error log and simply never reacts. The callback is still registered as a fast path when it does fire.

Brightness is only written when the docking state *changes*, or on wake while docked, because macOS relights the panel itself. Adjusting the built-in panel by hand while docked is never fought or overwritten. On its first check while undocked, the service keeps the current brightness, and restores the saved one only if the panel was left dark. When the service stops while docked, it relights the panel first. The rules are specified by `Tests/lidlessTests/PolicyTests.swift`.

The binary carries an ad-hoc signature only. lidless asks for no privacy permission, so nothing is tied to its signature or path, and an upgrade or a move needs nothing granted again.

## Cost

Measured on this machine, one poll every 2 seconds (43,200 per day):

| Operation | Per call | Per day |
|---|---|---|
| Topology scan (every tick) | 50 µs | 2.2 s |
| Brightness read (undocked only) | 50 µs | 2.1 s |
| State write, value unchanged | 1 ns | ~0 |
| State write, value changed | 431 µs | only on real change |

Roughly 2–4 seconds of CPU per day, about 0.003% of one core. Over a 10-second sample: no measurable CPU time, zero idle wakeups, a flat 3.4 MB of private memory, power score 0.0. The poll timer carries a 1-second tolerance so macOS can coalesce its wakeup with other timers.

The state write is guarded by a cached comparison. Without that guard it would rewrite the same value on every tick while undocked: 43,200 disk writes a day, and most of the tool's cost.

## Known limitation

The panel goes dark but stays a display as far as macOS is concerned, so in extended-display mode the cursor and windows can still wander onto a black screen. Genuinely disconnecting it needs private SkyLight calls that are fragile across OS versions. Mirroring the built-in to the external avoids the problem.

## Changelog

### 0.2.0 — 2026-11-01

Installed from a prebuilt release instead of built from source, and controlled with `lidless <command>` instead of flags. Stopping the service while docked relights the panel.

Upgrading from 0.1.x with `install.sh`: `launchctl bootout gui/$UID/com.local.lidless; rm ~/Library/LaunchAgents/com.local.lidless.plist ~/.local/bin/lidless`, then run the installer. With Homebrew: `brew upgrade lidless && brew services restart lidless`.

### 0.1.1

Re-darken the panel on wake while docked, and keep the current brightness on first start.

### 0.1.0

First release.

## License

MIT — see [LICENSE](LICENSE).
