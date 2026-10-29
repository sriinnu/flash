# Security

Flash watches security-key traffic, auth dialogs and git prompts, so a bug here can matter more than it would in most menu-bar apps.

**Report a vulnerability privately:** use [Report a vulnerability](https://github.com/sriinnu/flash/security/advisories/new) on this repo. Please don't open a public issue for it.

Worth knowing when you look:

- Flash never reads key material, PINs or passwords. `flash-askpass` passes what you type straight to the caller (git or ssh) and doesn't store it.
- The FIDO sniffer opens keys non-exclusively and only parses CTAPHID keepalive and response headers.
- `flash-notify` writes to `~/Library/Application Support/Flash/inbox/`; files older than 30s are dropped unread.
- Releases are Developer ID signed and notarized, and the release assets are immutable once published. Check a download against `SHA256SUMS` on its release page.

Only the latest release gets fixes.
