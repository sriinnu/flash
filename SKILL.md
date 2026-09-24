---
name: flash
description: Work on Flash, a macOS menu-bar app (Swift/AppKit/SwiftUI, no deps) that animates the screen edges when a FIDO security key needs a touch. Use when changing alert effects, detection (FIDO sniffer, SSH-signing wrapper), the menu-bar panel or settings, or when building, releasing, or helping someone set Flash up with git.
---

# Flash

The full developer guide is in `DEVELOPMENT.md`. The user-facing setup is in `README.md`. This file covers the working rules for an agent.

## Orient first

- `Sources/Flash/` is one SwiftPM executable target, macOS 14+, Swift 5.9 tools.
- **Flow:** detection (`FidoSniffer`, `SignTrigger`) calls `FlashController.trigger` / `resolve`. The controller creates one `OverlayWindow` per screen, and each window hosts an `OverlayView` effect.
- All effects draw on `BorderGeometry`. Shared layer and keyframe helpers live on `OverlayView` in `FlashOverlay.swift`.
- UserDefaults keys: `alertStyle`, `flashColor`, `flashCount`, `reminderInterval`, `successRipple`, `watchingEnabled`, `statsDay`, `statsTouches`.

## Build and verify

- It only builds on macOS: `make run` builds, bundles and runs in the foreground. On Linux there's no AppKit or `codesign`, so say plainly that the change is **uncompiled** and give the user the exact commands to verify it.
- Manual check after UI or effect changes: menu-bar panel → **Test flash** with each style, **Test success**, Settings → **Preview**, then Classic with Reduce Motion on.
- Scripts: `bash -n` + `shellcheck` on `tools/*.sh` and `tools/git-ssh-keygen-flash`. They have to stay bash 3.2 compatible.

## Conventions

- No third-party dependencies. Main-actor work goes through `FlashController` (`@MainActor`). From AppKit or SwiftUI callbacks, hop with `Task { @MainActor in … }`, the same way the existing code does.
- Comments explain *why*, in the owner's voice. Where a person would be named, the name is "Sriinnu".
- New alert styles need a distinct *motion*, not just a new colour (see DEVELOPMENT.md → Adding an alert style).
- Keep model layer values invisible after an animation. Wrap effects in `runTransaction` so the window orders out on completion.
- Version comes only from `Resources/Info.plist` → `CFBundleShortVersionString`. Tags are `v<version>`.
- Commits: no `Co-Authored-By` or other AI-attribution trailers.

## Helping a user set up git

Point `gpg.ssh.program` at `/Applications/Flash.app/Contents/Resources/git-ssh-keygen-flash` (full steps are in README → Set up git).

- The wrapper only alerts for `-Y sign` with an `sk-` key, and only while Flash is running.
- If Apple's `ssh-keygen` rejects the key type, set `FLASH_SSH_KEYGEN=/opt/homebrew/bin/ssh-keygen`.
- **Protocol:** `SIGUSR1` before signing, exit code written to `$TMPDIR/flash-signing-result`, then `SIGUSR2`. If you change it, change both `tools/git-ssh-keygen-flash` and `SignTrigger.swift`.

## Releasing

To release: bump the plist, commit, then `git tag vX.Y && git push origin vX.Y`. `.github/workflows/release.yml` runs `tools/release.sh --publish`. The signing and notarization secrets are listed in DEVELOPMENT.md → Releasing. Never commit `.p12` or `.p8` files.
