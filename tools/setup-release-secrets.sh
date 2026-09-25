#!/usr/bin/env bash
#
# setup-release-secrets.sh — push every release secret to GitHub in one go.
#
#   make release-secrets        (or: tools/setup-release-secrets.sh)
#
# Instead of base64-ing files and pasting seven values into the web UI:
# point it at your .p12 and .p8, answer three prompts, done. Values go
# straight from this Mac to GitHub's encrypted secrets via `gh secret set`:
# never echoed, never written to disk, never in shell history.
#
# Finds on its own:
#   DEVELOPER_ID   from your keychain (Developer ID Application identity)
#   NOTARY_KEY_ID  from the .p8 filename (AuthKey_<KEYID>.p8)
#   .p12 / .p8     newest match in ~/Downloads, ~/Desktop, ~/Documents
#
# Also offers to create the public sriinnu/homebrew-tap repo if missing,
# and to save a local notarytool profile for `make publish`.
#
# Already have these from other apps? They're per Apple team, not per app:
# the same Developer ID certificate and API key sign and notarize Flash too.
# Lost the .p8? It only downloads once. Make a new key in App Store Connect
# (Team Keys → +); old keys and the projects using them keep working.

set -euo pipefail

REPO="${REPO:-sriinnu/flash}"
TAP_REPO="${TAP_REPO:-sriinnu/homebrew-tap}"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ask() {        # ask "prompt" [default] → echo answer
    local answer
    read -r -p "  $1${2:+ [$2]}: " answer </dev/tty
    printf '%s' "${answer:-${2:-}}"
}
ask_secret() { # ask_secret "prompt" → echo answer, typed hidden
    local answer
    read -r -s -p "  $1: " answer </dev/tty
    printf '\n' >/dev/tty
    printf '%s' "$answer"
}
confirm() { [[ "$(ask "$1 (y/n)" y)" =~ ^[Yy] ]]; }

# newest file matching a glob in the usual drop folders
find_newest() {
    local f
    # shellcheck disable=SC2086,SC2012  # globs are the point; newest-first is all we need
    f="$(ls -t $HOME/Downloads/$1 $HOME/Desktop/$1 $HOME/Documents/$1 2>/dev/null | head -n 1 || true)"
    printf '%s' "$f"
}

set_secret() { # set_secret NAME  (value on stdin)
    gh secret set "$1" --repo "$REPO" >/dev/null
    ok "$1"
}

# ── Preflight ────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "run this on your Mac"
command -v gh >/dev/null || die "needs the GitHub CLI: brew install gh"
gh auth status >/dev/null 2>&1 || die "run: gh auth login"
echo "Setting release secrets on $REPO."

# ── 1. Developer ID certificate ──────────────────────────────────────────
bold "1. Developer ID certificate (signing)"
identities="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | sort -u)"
count="$(printf '%s' "$identities" | grep -c . || true)"
if [[ "$count" -eq 0 ]]; then
    die "no 'Developer ID Application' identity in your keychain. Install the .cer from developer.apple.com first."
elif [[ "$count" -eq 1 ]]; then
    developer_id="$identities"
else
    echo "  Several found:"
    printf '%s\n' "$identities" | nl -w4 -s') '
    developer_id="$(printf '%s\n' "$identities" | sed -n "$(ask 'Which one' 1)p")"
fi
ok "identity: $developer_id"

p12="$(ask "Path to the exported .p12" "$(find_newest '*.p12')")"
p12="${p12/#\~/$HOME}"
[[ -f "$p12" ]] || die "not found: $p12  (Keychain Access → My Certificates → right-click → Export)"
p12_password="$(ask_secret "Password you set when exporting the .p12")"
# Check it opens before uploading, so CI doesn't find out the hard way.
openssl pkcs12 -in "$p12" -passin "pass:$p12_password" -noout -legacy 2>/dev/null \
    || openssl pkcs12 -in "$p12" -passin "pass:$p12_password" -noout 2>/dev/null \
    || die "that password doesn't open $p12"

# ── 2. App Store Connect API key ─────────────────────────────────────────
bold "2. App Store Connect API key (notarization)"
p8="$(ask "Path to AuthKey_XXXX.p8" "$(find_newest 'AuthKey_*.p8')")"
p8="${p8/#\~/$HOME}"
[[ -f "$p8" ]] || die "not found: $p8"
key_id_guess="$(basename "$p8" | sed -n 's/^AuthKey_\([A-Z0-9]*\)\.p8$/\1/p')"
key_id="$(ask "Key ID" "$key_id_guess")"
issuer="$(ask "Issuer ID (top of the Team Keys page, a UUID)")"
[[ "$issuer" =~ ^[0-9a-fA-F-]{36}$ ]] || die "that doesn't look like an Issuer ID (UUID)"

# ── 3. Homebrew tap ──────────────────────────────────────────────────────
bold "3. Homebrew tap ($TAP_REPO)"
if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
    ok "tap repo exists"
elif confirm "Create public repo $TAP_REPO now?"; then
    gh repo create "$TAP_REPO" --public \
        --description "Homebrew tap for Flash — brew install --cask ${TAP_REPO%%/*}/tap/flash" >/dev/null
    ok "created $TAP_REPO"
else
    echo "  Skipping. Create it before the first tagged release."
fi
tap_token="$(ask_secret "Fine-grained token (Contents: read & write on $TAP_REPO), empty to skip")"

# ── Upload ───────────────────────────────────────────────────────────────
bold "Uploading to $REPO"
base64 -i "$p12" | set_secret DEVELOPER_ID_P12_BASE64
printf '%s' "$p12_password" | set_secret DEVELOPER_ID_P12_PASSWORD
printf '%s' "$developer_id" | set_secret DEVELOPER_ID
base64 -i "$p8" | set_secret NOTARY_KEY_P8_BASE64
printf '%s' "$key_id" | set_secret NOTARY_KEY_ID
printf '%s' "$issuer" | set_secret NOTARY_ISSUER
if [[ -n "$tap_token" ]]; then
    printf '%s' "$tap_token" | set_secret HOMEBREW_TAP_TOKEN
fi

# ── Optional: local notarization profile ─────────────────────────────────
bold "Local releases (optional)"
profile="$(ask "Existing notarytool profile from other projects (empty = create 'flash-notary', 'skip' = none)")"
if [[ -z "$profile" ]]; then
    xcrun notarytool store-credentials flash-notary --key "$p8" --key-id "$key_id" --issuer "$issuer"
    profile=flash-notary
fi
if [[ "$profile" != "skip" ]]; then
    # Cheap check that the profile works: listing history needs valid creds.
    if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
        ok "profile '$profile' works"
    else
        echo "  ⚠ couldn't use profile '$profile' — check the name (xcrun notarytool history --keychain-profile …)"
    fi
    echo "  Local: DEVELOPER_ID=\"$developer_id\" NOTARY_PROFILE=$profile make publish"
fi

bold "Done"
echo "  Next: Actions → Release → Run workflow (dry run), then: git tag v0.3 && git push origin v0.3"
echo "  Keep the .p12 and .p8 somewhere safe (a password manager), outside any repo."
