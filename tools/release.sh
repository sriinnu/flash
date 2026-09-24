#!/usr/bin/env bash
#
# Build a distributable Flash release: universal .app → signed → (notarized)
# → Flash-<version>.dmg + Flash-<version>.zip + SHA256SUMS in dist/.
#
#   tools/release.sh                 # build artifacts only
#   tools/release.sh --publish       # …and create the GitHub release (gh CLI)
#
# Version comes from Resources/Info.plist (CFBundleShortVersionString) — one
# source of truth. The build number is the commit count, so it only ever
# goes up. Sriinnu: bump the plist, commit, then tag/run this.
#
# Signing is picked from the environment, best available wins:
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#       → hardened-runtime Developer ID signature. Without it: ad-hoc, which
#         runs fine but Gatekeeper makes users approve it on first launch.
#
#   Notarization (needs DEVELOPER_ID too), either:
#     NOTARY_PROFILE=<name>          keychain profile from
#                                    `xcrun notarytool store-credentials`
#     NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER
#                                    App Store Connect API key (CI)
#
#   KEYCHAIN=<path>                  optional keychain to sign from (CI)

set -euo pipefail

cd "$(dirname "$0")/.."

PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 64 ;;
    esac
done

say()  { printf '\033[1;33m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "releases build on macOS only (swift + codesign + hdiutil)"
for tool in swift codesign ditto hdiutil shasum /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

PLIST_SRC="Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_SRC")"
BUILD="$(git rev-list --count HEAD)"
TAG="v${VERSION}"

# In CI the tag *is* the trigger — refuse to publish a tag that disagrees
# with the plist, or users download "v0.4" that reports itself as 0.3.
if [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_TYPE:-}" == "tag" && "$GITHUB_REF_NAME" != "$TAG" ]]; then
    die "tag $GITHUB_REF_NAME doesn't match Info.plist version $VERSION (expected $TAG)"
fi

if [[ -z "${CI:-}" && -n "$(git status --porcelain)" ]]; then
    die "working tree is dirty — commit first so the release matches a real commit"
fi

DIST="dist"
APP="$DIST/Flash.app"
ZIP="$DIST/Flash-${VERSION}.zip"
DMG="$DIST/Flash-${VERSION}.dmg"

say "Flash $VERSION (build $BUILD)"
rm -rf "$DIST"
mkdir -p "$DIST"

# ── 1. Universal binary ─────────────────────────────────────────────────
say "building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BINARY="$BIN_DIR/Flash"
[[ -x "$BINARY" ]] || die "binary not found at $BINARY"
lipo -info "$BINARY"

# ── 2. Bundle ───────────────────────────────────────────────────────────
say "assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Flash"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
cp Resources/Flash.icns "$APP/Contents/Resources/Flash.icns"
# Ships inside the bundle so dmg users can point git at it — see README.
cp tools/git-ssh-keygen-flash "$APP/Contents/Resources/git-ssh-keygen-flash"

# ── 3. Sign ─────────────────────────────────────────────────────────────
# macOS ships bash 3.2, where "${empty[@]}" trips `set -u` — hence the
# ${arr[@]+"${arr[@]}"} dance wherever an array may be empty.
KEYCHAIN_ARGS=()
if [[ -n "${KEYCHAIN:-}" ]]; then KEYCHAIN_ARGS=(--keychain "$KEYCHAIN"); fi

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    say "signing with Developer ID (hardened runtime)"
    codesign --force --timestamp --options runtime \
        ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$DEVELOPER_ID" "$APP"
    SIGNED=1
else
    say "no DEVELOPER_ID — ad-hoc signing (users will need to approve first launch)"
    codesign --force --sign - "$APP"
    SIGNED=0
fi
codesign --verify --strict --verbose=2 "$APP"

# ── 4. Notarize the app (optional) ──────────────────────────────────────
NOTARY_ARGS=()
CAN_NOTARIZE=0
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    CAN_NOTARIZE=1
elif [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    CAN_NOTARIZE=1
fi

notarize() {  # $1 = file to submit
    say "notarizing $(basename "$1") — usually a few minutes"
    xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait
}

NOTARIZED=0
if [[ $SIGNED -eq 1 && $CAN_NOTARIZE -eq 1 ]]; then
    # notarytool wants an archive; staple the ticket onto the .app itself so
    # it verifies offline, then build the real artifacts from the stapled app.
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    notarize "$DIST/notarize.zip"
    rm "$DIST/notarize.zip"
    xcrun stapler staple "$APP"
    NOTARIZED=1
elif [[ $SIGNED -eq 1 ]]; then
    say "no notary credentials — signed but not notarized"
fi

# ── 5. Artifacts ────────────────────────────────────────────────────────
say "zipping → $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

say "building disk image → $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target
hdiutil create -volname "Flash $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

if [[ $SIGNED -eq 1 ]]; then
    codesign --force --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$DEVELOPER_ID" "$DMG"
fi
if [[ $NOTARIZED -eq 1 ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS )

# ── 6. Release notes ────────────────────────────────────────────────────
NOTES="$DIST/RELEASE_NOTES.md"
PREV_TAG="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || git describe --tags --abbrev=0 2>/dev/null || true)"
[[ "$PREV_TAG" == "$TAG" ]] && PREV_TAG=""
{
    echo "## Install"
    echo
    echo "1. Download **Flash-${VERSION}.dmg**, open it, drag **Flash** into **Applications**."
    echo "2. Launch Flash — it lives in the menu bar (bolt-shield icon), no Dock icon."
    if [[ $NOTARIZED -eq 0 ]]; then
        echo
        echo "> **First launch:** this build isn't notarized by Apple, so macOS will block it once."
        echo "> Open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to Flash."
        echo "> Or in Terminal: \`xattr -dr com.apple.quarantine /Applications/Flash.app\`"
    fi
    echo
    echo "Requires macOS 14+ · universal (Apple Silicon + Intel) · build $BUILD"
    echo
    echo "## Changes"
    echo
    if [[ -n "$PREV_TAG" ]]; then
        git log --no-merges --format='- %s' "${PREV_TAG}..HEAD"
    else
        git log --no-merges --format='- %s' -20
    fi
    echo
    echo "Checksums (SHA-256):"
    echo '```'
    cat "$DIST/SHA256SUMS"
    echo '```'
} > "$NOTES"

say "done:"
( cd "$DIST" && du -h -- * )
echo "   signed: $([[ $SIGNED -eq 1 ]] && echo 'Developer ID' || echo 'ad-hoc')   notarized: $([[ $NOTARIZED -eq 1 ]] && echo yes || echo no)"

# ── 7. Publish ──────────────────────────────────────────────────────────
if [[ $PUBLISH -eq 1 ]]; then
    command -v gh >/dev/null || die "--publish needs the GitHub CLI (brew install gh)"
    if gh release view "$TAG" >/dev/null 2>&1; then
        die "release $TAG already exists — bump CFBundleShortVersionString"
    fi
    say "publishing GitHub release $TAG"
    # --target pins the tag to the exact commit built, if it doesn't exist yet.
    gh release create "$TAG" "$DMG" "$ZIP" "$DIST/SHA256SUMS" \
        --title "Flash $VERSION" \
        --notes-file "$NOTES" \
        --target "$(git rev-parse HEAD)"
fi
