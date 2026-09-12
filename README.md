# lidless

Turns the built-in MacBook display off whenever an external monitor is connected,
and restores its previous brightness when you unplug — clamshell-mode behaviour
without closing the lid.

No third-party apps and no Accessibility permission: a single ~90 KB Swift binary
built with the system toolchain, registered as a launchd login agent.

## Install

### Homebrew

```bash
brew trust --tap https://github.com/np25071984/lidless
brew tap np25071984/lidless https://github.com/np25071984/lidless
brew install lidless
brew services start lidless
```

The two-argument `brew tap` points at this repository directly, so the formula
lives alongside the source instead of in a separate `homebrew-*` tap. Upgrades
are the usual `brew upgrade lidless`.

The `brew trust` step is not optional. Current Homebrew refuses to load formulae
from third-party taps until they are trusted, and the failure is reported as
`Error: Cannot tap ...: invalid syntax in tap!`, which is misleading — there is
nothing wrong with the formula. Trust is matched against the tap's **remote
URL**, not its short `user/repo` name, so `brew trust --tap np25071984/lidless`
does not work here; the URL form above is what matches.

Homebrew builds from source with `swiftc`, so the Command Line Tools must be
installed (`xcode-select --install`). Full Xcode is not required.

### From source

```bash
./install.sh
```

Builds `~/.local/bin/lidless`, writes `~/Library/LaunchAgents/com.local.lidless.plist`,
and starts it. It runs at login and restarts itself if it dies.

Do not run both: if you installed via `install.sh` and later switch to Homebrew,
remove the hand-rolled agent first, or two copies will fight over the backlight.

```bash
launchctl unload ~/Library/LaunchAgents/com.local.lidless.plist
rm ~/Library/LaunchAgents/com.local.lidless.plist
```

## Usage

The agent needs no interaction. For manual control:

| Command | Effect |
|---|---|
| `lidless --status` | List online displays, their brightness, and dock state |
| `lidless --once` | Apply the correct state right now, then exit |
| `lidless --off` | Force the built-in display off |
| `lidless --on` | Force the built-in display back on |
| `lidless --version` | Print the version |
| `lidless --help` | Print usage |

Transitions are logged to `~/.local/state/lidless.log`, or to
`$(brew --prefix)/var/log/lidless.log` under `brew services`. The brightness to restore
on undock is remembered in `~/.local/state/lidless-brightness`.

## How it works

Brightness is driven through `DisplayServicesSetBrightness` from the private
`DisplayServices` framework, resolved at runtime with `dlsym` — on Apple Silicon
that is the only way to control the built-in panel's backlight. Setting it to
`0.0` switches the backlight off; that is the same value macOS itself parks the
panel at when the lid is shut.

Two details that are easy to get wrong:

- **The built-in panel is found via `CGGetOnlineDisplayList`, not
  `CGGetActiveDisplayList`.** With the lid shut or while mirroring, it drops out
  of the active list while still being the display whose backlight matters.
- **Docking state is polled every 2 seconds rather than driven by
  `CGDisplayRegisterReconfigurationCallback`.** That callback is not delivered to
  a background launchd agent, which fails silently — the process stays alive with
  an empty error log and simply never reacts. The callback is still registered as
  a fast path when it does fire.

Brightness is only written when the docking state *changes*, so adjusting the
built-in panel by hand while docked is never fought or overwritten.

## Cost

Measured on this machine, one poll every 2 seconds (43,200 per day):

| Operation | Per call | Per day |
|---|---|---|
| Topology scan (every tick) | 50 µs | 2.2 s |
| Brightness read (undocked only) | 50 µs | 2.1 s |
| State write, value unchanged | 1 ns | ~0 |
| State write, value changed | 431 µs | only on real change |

Roughly 2–4 seconds of CPU per day, about 0.003% of one core. Over a 10-second
sample: no measurable CPU time, zero idle wakeups, a flat 3.4 MB of private
memory, power score 0.0. The poll timer carries a 1-second tolerance so macOS can
coalesce its wakeup with other timers.

The state write is guarded by a cached comparison. Without that guard it rewrote
the same value on every tick while undocked — 43,200 disk writes a day, and 86%
of the tool's entire cost.

## Known limitation

The panel goes dark but stays a display as far as macOS is concerned, so in
extended-display mode the cursor and windows can still wander onto a black
screen. Genuinely disconnecting it needs private SkyLight calls that are fragile
across OS versions. Mirroring the built-in to the external avoids the problem.

## Uninstall

```bash
./uninstall.sh
```
