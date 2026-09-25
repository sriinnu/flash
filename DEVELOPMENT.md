# Flash: developer guide

This is a menu-bar-only macOS app written in Swift, using AppKit and SwiftUI. It has **no dependencies**. Everything builds with SwiftPM plus a small Makefile.

## Quick start

```sh
make run       # build, bundle, run in the foreground; logs stream to the terminal
make install   # build + replace /Applications/Flash.app (kills the running copy)
make icon      # Resources/logo.svg → logo.png + Flash.icns (needs: npm i --no-save playwright-core)
make release   # universal, signed dmg + zip in dist/ (see Releasing)
make selftest  # guided test of every detection path, needs Flash running
make clean
```

Requirements: macOS 14+ and Xcode 15+ (Swift 5.9). A FIDO key is needed for real tests. Test Flash and Preview work without one.

Logs go to `~/Library/Logs/Flash.log`. They're always written, including when the app is launched from Finder.

## Architecture

```
            ┌──────────────────── detection ─────────────────────┐
 FIDO key ──────► FidoSniffer (IOHID, CTAPHID keepalive)          │
 git sign ──────► git-ssh-keygen-flash ─SIGUSR1/2─► SignTrigger   │
 auth dialogs ──► AuthPromptWatcher (window owners, 750ms poll)   │
 askpass/hooks ─► flash-notify ─file─► EventInbox ─► InboxRouter  │
            └──────────────────────────┬─────────────────────────┘
                                       │ trigger(id) / resolve(id, success)
                                ▼
                  FlashController  (@MainActor, one per app)
                   • active trigger set + watchdog (45s)
                   • reminder → escalates to Classic
                   • icon state, touch stats
                                │ one OverlayWindow per NSScreen
                                ▼
       OverlayWindow ─hosts─► OverlayView subclass (one effect, single use)
                              Classic · Comet · Marquee · TargetLock
                              Heartbeat · SuccessRipple
                                ▲
                  BorderGeometry: one rail every effect draws on

 repos (FSEvents) ─► RepoActivityWatcher ─┐
 hooks (attrib) ──► InboxRouter ──────────┴─► ActivityLog ─► menu-bar panel
                                              (never flashes)
```

**Rule of thumb for new detectors:** only something that is *blocked on the user* calls `FlashController.trigger`. Everything else (commits, pushes, stats) goes to `ActivityLog`. Firing the full-screen alert for things that don't need the user trains them to ignore it.

| File | What lives there |
|---|---|
| `FlashApp.swift` | App entry, `AppDelegate`: status item, popover, right-click menu, singleton guard, crash breadcrumbs |
| `FlashController.swift` | Trigger state, watchdog, reminders/escalation, touch stats, spawns overlay windows |
| `FlashOverlay.swift` | `OverlayWindow`, `OverlayView` base + shared helpers, `BorderGeometry`, Classic, Comet, SuccessRipple |
| `AlertEffects.swift` | Marquee, Target lock, Heartbeat |
| `MenuPanelView.swift` | Left-click popover |
| `SettingsView.swift` | Tabbed Settings (Alerts / Detection / About), `StyleTile`, `Swatch` |
| `Settings.swift` | `FlashColor`, `AlertStyle`, `ReminderInterval`, `FlashSettings` (UserDefaults) |
| `WatchManager.swift` | Starts and stops every detection engine as one; pause state |
| `FidoSniffer.swift` | IOHID manager on usage page `0xF1D0`, CTAPHID parser |
| `SignTrigger.swift` | `SIGUSR1` = touch needed, `SIGUSR2` = done (exit code in `$TMPDIR/flash-signing-result`) |
| `EventInbox.swift` | Inbox folder watcher + `InboxRouter` (`prompt.begin/end`, `attrib`) |
| `AuthPromptWatcher.swift` | Polls on-screen window owners (`SecurityAgent`, `coreautha`, `pinentry-mac`) |
| `RepoActivityWatcher.swift` | FSEvents on watched roots; parses reflogs (`commit…`, `update by push`) |
| `ActivityLog.swift` | `ActivityEvent`, `Actor`, the in-memory log shown in the panel |
| `SSHPromptRouting.swift` | `launchctl setenv SSH_ASKPASS…` toggle |
| `Log.swift` | stdout + `~/Library/Logs/Flash.log` |
| `tools/git-ssh-keygen-flash` | `gpg.ssh.program` wrapper, shipped in `Contents/Resources` |
| `tools/flash-notify` | The one client for the inbox; works out agent vs you from the process tree |
| `tools/flash-askpass` | `core.askPass` / `SSH_ASKPASS`: flashes, then asks through a dialog |
| `tools/git-hooks/` | Optional global hooks: forward to the repo's own hooks, then report who made the change |
| `Resources/logo.svg` | Icon master. The screen tile, two comets colliding at the bottom, a bolt striking the collision point. `logo.png` and `Flash.icns` are rendered from it |
| `tools/render-logo.mjs` | SVG → PNG + `.icns` through headless Chrome (every size rendered from the vector) |
| `tools/update-cask.sh` + `packaging/homebrew/` | Homebrew cask template → `sriinnu/homebrew-tap` |
| `tools/release.sh` | Release pipeline (build → sign → notarize → dmg/zip → GitHub) |
| `tools/flash-selftest` | `make selftest`: triggers each detection path for real, records pass/fail |

### Detection notes

- **FidoSniffer** opens keys non-exclusively and watches for `KEEPALIVE` with status `UP_NEEDED`. A response packet means the key was touched; `ERROR` means it was cancelled. Some HID stacks prepend a report-ID byte, so the parser checks offset 0 and then offset 1.
- **SSH signing:** libfido2 *seizes* the device (`kIOHIDOptionsTypeSeizeDevice`) during a signature, which evicts the sniffer. That's why signing has its own signal path through the wrapper.
- The **watchdog** clears any trigger that never resolves within 45s. Without it, a crashed helper would leave its id "active" forever and silently swallow every future alert.

### Event inbox protocol

`flash-notify key=value …` writes one file into `~/Library/Application Support/Flash/inbox/` containing `ts`, `actor`, `agent` and `app` fields, followed by the caller's fields. Files older than 30s are dropped unread.

| `event=` | Fields | Effect |
|---|---|---|
| `prompt.begin` | `id`, `kind` (`touch`, `ssh-passphrase`, `pin`, `password`, `username`, `confirm`) | Alert + log entry |
| `prompt.end` | `id`, `ok` (`1`/`0`) | Resolve; green ripple only on `ok=1` |
| `attrib` | `sha` | Sets who made that commit/push in the activity log |

Debug a prompt that doesn't alert: `FLASH_DEBUG_WINDOWS=1 make run` logs every window owner that appears on screen.

## Adding an alert style

1. Subclass `OverlayView` and override `play(completion:)`. Build layers with `strokeLayer`, `glow`, `keyframes(_:_:over:eased:)` and `group`. Keep geometry on `BorderGeometry` (`loop`, `half`, `quarter`, `perimeter`, `gradientRail`).
2. Wrap every animation in `runTransaction { … }` so `completion` fires when the whole effect finishes. That's what orders the window out.
3. Leave model values invisible (opacity 0, `strokeEnd` 0), so nothing lingers between the last frame and `orderOut`.
4. Add the case to `AlertStyle` (label + blurb), a symbol and short label in `SettingsView.swift`, and a branch in `FlashController.pulseAll`.
5. Give it a *different motion* from the existing ones (travel, flow, snap, rhythm). A new style that only differs in colour isn't worth a setting.

Reduce Motion and reminder escalation force Classic automatically. Nothing to do per style.

## Releasing

Version lives in **one place**: `CFBundleShortVersionString` in `Resources/Info.plist`. The build number is `git rev-list --count HEAD`.

```sh
# bump Info.plist → commit → tag
git tag v0.3 && git push origin v0.3      # CI: .github/workflows/release.yml publishes
# or locally
make publish                              # needs gh + the env below
```

CI refuses a tag that doesn't match the plist. Running the workflow manually (*Actions → Release → Run workflow*) is a dry run: it builds and uploads artifacts but doesn't publish.

| Where | Signing | Notarization |
|---|---|---|
| Local | `DEVELOPER_ID="Developer ID Application: Name (TEAMID)"` | `NOTARY_PROFILE=<name>` from `xcrun notarytool store-credentials` |
| GitHub secrets | `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `DEVELOPER_ID` | `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` |

**Notarization** fails loudly. On a rejection, `release.sh` prints Apple's log with the exact reasons. On success it staples, runs `stapler validate`, and runs `spctl --assess`, which should say "Notarized Developer ID".

**Homebrew.** After a tagged release publishes, CI runs `tools/update-cask.sh`. It renders `packaging/homebrew/flash.rb.template` with the version and the dmg's sha256, then writes `Casks/flash.rb` to `sriinnu/homebrew-tap` through the GitHub contents API, so the commit is GitHub-signed. It needs the `HOMEBREW_TAP_TOKEN` secret: a fine-grained PAT with Contents: read & write on the tap repo only. Preview locally with `make cask`.

Without them, the release still ships ad-hoc signed, and the notes tell users how to approve the first launch.

## Gotchas

- **Finder caches app icons.** After `make icon`, reinstall and `killall Finder`.
- **The singleton guard exits a second instance at launch.** If `make run` seems to quit instantly, a launch-at-login copy is already running: `pkill -x Flash`.
- **TCC grants bind to the code signature.** Expect one re-grant when switching between ad-hoc and Developer ID builds.
- **Settings has a fixed size.** `SettingsView.windowSize` is 460 × min(560, screen − 80). Content goes into the Alerts / Detection / About tabs, each of which scrolls. Don't go back to sizing the window from SwiftUI's measured height: it overflowed laptop screens.
- **Accessory apps aren't active by default.** The popover calls `NSApp.activate` first, or ⌘-shortcuts and click-outside-to-close misbehave.
- **macOS ships bash 3.2.** Scripts avoid bash 4 features and guard empty array expansions under `set -u`.

## Roadmap

See `TODO.md`: GUI password-dialog watcher (AX), terminal prompt watcher, per-trigger colours, display picker.
