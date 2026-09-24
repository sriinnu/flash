<p align="center">
  <img src="Resources/logo.png" width="160" alt="Flash logo">
</p>

<h1 align="center">Flash</h1>

<p align="center">
  A menu-bar alerter for the moment your Titan key wants a touch and you're looking somewhere else.
</p>

---

## Why

The Titan's touch LED is easy to miss — a small blink on a USB dongle is no match for a monitor you're not looking at. Every time a `git commit`/`git push` needs a signature, or a password dialog or terminal prompt is waiting on you, Flash pulses the edges of every display a few times and stops. Full-screen, impossible to miss from across the room, gone as soon as it's made its point.

## What it does

- **FIDO/Titan sniffer** — watches CTAPHID traffic for `KEEPALIVE/UP_NEEDED` (touch requested).
- **SSH-signing watcher** — hooks the `git-ssh-keygen-titan` wrapper directly via `SIGUSR1`/`SIGUSR2`, since libfido2 opens the key with `kIOHIDOptionsTypeSeizeDevice` during a real signature, which evicts any app trying to sniff that traffic non-exclusively.
- Menu-bar status item only — no dock icon, no windows. Icon tints amber while something's waiting, green for a few seconds after a confirmed touch.
- **Alert styles** — pick one in Settings (with a Preview button):
  - **Comet chase** (default) — two comets race from top-centre down both edges and collide at bottom-centre, pointing your eyes toward the key.
  - **Marquee** — two-tone marquee lights chase round the whole border.
  - **Target lock** — corner brackets slam in, lock, blink, then trace the full border and flare.
  - **Heartbeat** — the border thumps inward, lub-dub, three beats.
  - **Classic flash** — the full border pulses on and off.

  If a reminder fires, it always escalates to **classic**. Reduce Motion always gets classic.
- **Success ripple** — green rings collapse inward when the touch lands.
- Settings: alert style, flash color, classic flash count, reminder re-pulse if you miss it, success ripple, launch at login.

GUI password-dialog and terminal-prompt watchers are next — see `TODO.md`.

## Install

Grab the latest **Flash-x.y.dmg** from [Releases](https://github.com/sriinnu/flash/releases), open it, drag **Flash** into **Applications**, launch it — it lives in the menu bar. Universal build (Apple Silicon + Intel), macOS 14+.

If a release isn't notarized, macOS blocks the first launch: **System Settings → Privacy & Security → Open Anyway**.

## Release

Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, then:

```sh
git tag v0.3 && git push origin v0.3   # GitHub Actions builds, signs, notarizes, publishes
make release                           # or locally: artifacts in dist/
make publish                           # or locally + create the GitHub release (gh CLI)
```

Signing/notarization secrets are documented at the top of `.github/workflows/release.yml` and `tools/release.sh`.

## Build & run

```sh
make install   # → /Applications/Flash.app
make run       # run from a terminal, for watching sniffer logs live
make icon      # regenerate the app icon from tools/render_icon.swift
```

Logs: `~/Library/Logs/Flash.log`

## Requirements

- macOS 14+
- A FIDO2 security key (built and verified against a Titan Security Key v2)
- Swift 5.9 toolchain, no external dependencies
