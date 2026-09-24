# Flash — TODO

Border-flash alerter for auth prompts. Menu-bar resident macOS app (Swift/AppKit, no deps).
When anything asks for a secret — Titan touch, password dialog, terminal prompt — the screen
edges pulse 3–4 times and stop. One sequence per prompt, then it rearms.

**Build/run:** `make install` → `/Applications/Flash.app` · `make run` for terminal debugging
**Logs:** `~/Library/Logs/Flash.log`
**Icon:** `make icon` (regenerates from `tools/render_icon.swift`)

---

## ✅ Built & verified

- [x] **Border overlay** — borderless click-through window per display, two-tone neon gradient
      stroke + glow, keyframe pulse (count configurable 2–6), auto-dismiss. Verified via Test Flash.
- [x] **FIDO/Titan sniffer** — IOHIDManager, usage page `0xF1D0`, non-exclusive open, CTAPHID
      parser. Detects `KEEPALIVE/UP_NEEDED` (touch requested) vs response (touched ✅) vs
      `ERROR` (cancelled). Verified: attaches to "Titan Security Key v2", zero permission prompts.
- [x] **Menu bar shell** — AppKit status item, no dock icon. Pause/Resume Watching (persisted),
      Test Flash, Settings, Quit.
- [x] **Icon as status light** — idle: plain shield · alerting: amber · success: green for 4s
      after confirmed touch. Green only on real touch, not cancel.
- [x] **Settings** — 4 gradient color presets (amber/cyan/magenta/lime), reminder re-pulse timer
      (off/15/30/60s), flash count, launch at login (SMAppService).
- [x] **App icon** — navy tile, gold gradient bolt-shield w/ glow. `iconutil` pipeline in Makefile.
- [x] **Singleton** — second instance exits on launch (verified: 1 survivor). `make install`
      pkills old instance first.
- [x] **Install** — `/Applications/Flash.app`, terminal-free lifecycle.

## ⏳ Blocked on user: LIVE TITAN TEST (make-or-break)

- [ ] Chrome → webauthn.io → Register → borders flash amber on their own, icon goes amber
- [ ] Touch key → icon green 4s → log shows `UP_NEEDED` then `response received — touch done ✅`
- [ ] Cancel instead of touch → returns to idle, NO green
- [ ] Check `~/Library/Logs/Flash.log` if anything's off

## 🔨 Remaining engines (build after live test passes)

- [ ] **GUI password-dialog watcher** (task #5)
      AX observer on new windows system-wide; trigger when window contains `AXSecureTextField`.
      Needs Accessibility permission (one-time grant, add onboarding prompt + deep link to
      System Settings). Catch: SecurityAgent auth dialogs, app unlock sheets, keychain prompts.
      Resolve = window closes. Success vs cancel: green only if dialog closed by confirmation —
      likely not distinguishable via AX; default to success on close, revisit if it annoys.
- [ ] **Terminal prompt watcher** (task #6)
      Poll AX text of Terminal.app + Ghostty windows (~1s cadence or on AXValueChanged).
      Match live prompt at cursor: `Password:`, `password for`, `passphrase`, `sudo`.
      Debounce per-window; ignore matches in scrollback (must be in last visible lines).
      Resolve when prompt text disappears. Success = new shell prompt appeared after; cancel
      = Ctrl+C (`^C` seen). Best effort — this engine is the soft one, false-negative tolerant.
- [ ] Wire both into WatchManager start/stop so Pause kills all engines.

## ✨ Polish backlog (post-MVP, user mentioned interest)

- [x] Success ripple/animation on touch — green rings collapse inward; toggle in Settings,
      "Test Success" in menu. **Needs eyes on real hardware.**
- [ ] **Comet chase alert** (built, untested on a Mac) — two comets race top-centre →
      bottom-centre, flare + shockwave on meet. Default alert style; reminders escalate to
      classic; Reduce Motion forces classic. Tune: tail lengths/alphas, travel 0.95s, 2 passes.
- [ ] **Marquee / Target lock / Heartbeat** (built, untested on a Mac) — extra alert styles
      in `AlertEffects.swift`, picker + Preview in Settings. Tune speeds/timings on real screens.
- [ ] Reminder is Off by default → a missed comet never escalates. Consider a one-shot
      auto-escalation (~8s) when reminders are off.
- [ ] Touch counter / stats in menu (today: N touches)
- [ ] Subtle success sound (optional, off by default)
- [ ] Per-trigger colors (gold = Titan, blue = password) — 5-line diff in pulseAll
- [ ] Caps-lock LED blink as secondary channel (Twitter-hack homage, IOKit LED control)
- [ ] Flash display picker (all displays vs prompt's display) — default stays "all"
- [ ] Icon state for "paused" (dim shield?)

## 📦 Distribution (when solid)

- [ ] Sign with Developer ID (user has Apple dev account)
- [ ] Notarize + staple
- [ ] `make release` target: versioned zip / dmg

## 🧠 Known gotchas / dev notes

- CTAPHID report may carry a leading report-ID byte on some stacks — parser checks offset 0
  then retries at offset 1. If a future key isn't detected, log the raw report first.
- Sniffer callbacks arrive on main runloop (commonModes). Keep it that way.
- Finder caches app icons aggressively — after `make icon`, reinstall + `killall Finder`.
- Ad-hoc signed; TCC (Accessibility) grants bind to the binary signature, so permission
  survives rebuilds only until real signing changes. Expect one re-grant when Developer ID lands.
- `FidoSniffer` buffers are deallocated on stop(); restart path verified once — keep an eye.
