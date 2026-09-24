<p align="center">
  <img src="Resources/logo.png" width="160" alt="Flash logo">
</p>

<h1 align="center">Flash</h1>

<p align="center">
  Your security key wants a touch and you're looking somewhere else.<br>
  Flash lights up the edges of every display so you can't miss it.
</p>

---

A security key's touch LED is tiny. Flash sits in the macOS menu bar, notices when a FIDO key (Titan, YubiKey, …) is waiting on you, and plays a short, full-screen edge animation, then gets out of the way. When the touch lands, a green ripple confirms it.

- **Catches** WebAuthn / passkey prompts in any browser, and SSH commit signing with a security key.
- **Five alert styles**: Comet chase, Marquee, Target lock, Heartbeat, Classic flash. Pick one and choose its colours in Settings.
- **Stays quiet**: menu-bar only, no Dock icon. If you ignore an alert, the reminder switches to the loud Classic flash. It respects Reduce Motion.

## Install

1. Download **Flash-x.y.dmg** from [Releases](https://github.com/sriinnu/flash/releases).
2. Open it and drag **Flash** into **Applications**.
3. Launch it. A bolt-shield icon appears in the menu bar.

macOS 14+, Apple Silicon and Intel. If macOS blocks the first launch, go to **System Settings → Privacy & Security → Open Anyway**.

Browser and passkey prompts work straight away. Git needs one more step.

## Set up git (SSH signing with a security key)

While git is signing, the key is locked to the signing process, so Flash can't see it. Flash ships a small wrapper that tells Flash itself. Point git at it:

```sh
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_sk.pub   # your sk- key
git config --global commit.gpgsign true
git config --global gpg.ssh.program \
  /Applications/Flash.app/Contents/Resources/git-ssh-keygen-flash
```

Now `git commit` alerts you when the key needs a touch, and ripples green when it's signed.

- **Only security keys (`sk-…`) trigger an alert.** Signing with an ordinary key passes through untouched, and so does anything other than signing.
- **If git says the key type isn't supported**, Apple's bundled `ssh-keygen` may lack FIDO support. Install `brew install openssh` and add `export FLASH_SSH_KEYGEN=/opt/homebrew/bin/ssh-keygen` to your shell profile.
- **Don't have a security-key SSH key yet?** Create one with `ssh-keygen -t ed25519-sk`.

## Use

- **Click the icon** for a panel with status, today's touch count, the style switcher, test buttons and a pause switch. **Right-click** gives a plain menu.
- **Settings** (⌘,) holds alert style, colour, reminder interval, success ripple and launch at login.
- **Logs** go to `~/Library/Logs/Flash.log`.

## Develop

Building, architecture, adding alert styles and cutting releases are covered in **[DEVELOPMENT.md](DEVELOPMENT.md)**.

<p align="center"><sub>Made by Sriinnu</sub></p>
