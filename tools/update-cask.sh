#!/usr/bin/env bash
#
# update-cask.sh — render the Homebrew cask for the current release and
# publish it to the tap.
#
#   tools/update-cask.sh --print            # just show the cask
#   tools/update-cask.sh                    # commit it to $TAP_REPO
#
# Version comes from Resources/Info.plist, the sha256 from dist/SHA256SUMS
# (so run tools/release.sh first). Publishing goes through the GitHub
# contents API rather than git push: commits made that way are signed by
# GitHub, which keeps the tap's history verified like the main repo's.
#
#   TAP_REPO   default sriinnu/homebrew-tap   → brew install --cask sriinnu/tap/flash
#   GH_TOKEN   token with Contents: write on TAP_REPO (CI: HOMEBREW_TAP_TOKEN)

set -euo pipefail
cd "$(dirname "$0")/.."

die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

TAP_REPO="${TAP_REPO:-sriinnu/homebrew-tap}"
CASK_PATH="Casks/flash.rb"
TEMPLATE="packaging/homebrew/flash.rb.template"

plist_version() {
    if [[ -x /usr/libexec/PlistBuddy ]]; then
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist
    else   # Linux / CI without PlistBuddy: the plist is plain XML
        sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Resources/Info.plist
    fi
}

VERSION="$(plist_version)"
[[ -n "$VERSION" ]] || die "couldn't read CFBundleShortVersionString"
DMG="Flash-${VERSION}.dmg"

[[ -f dist/SHA256SUMS ]] || die "dist/SHA256SUMS missing — run tools/release.sh first"
SHA256="$(awk -v f="$DMG" '$2 == f { print $1 }' dist/SHA256SUMS)"
[[ ${#SHA256} -eq 64 ]] || die "no sha256 for $DMG in dist/SHA256SUMS"

cask="$(sed -e "s/{{VERSION}}/$VERSION/" -e "s/{{SHA256}}/$SHA256/" "$TEMPLATE")"

if [[ "${1:-}" == "--print" ]]; then
    printf '%s\n' "$cask"
    exit 0
fi

command -v gh >/dev/null || die "needs the GitHub CLI (gh)"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN not set (needs Contents: write on $TAP_REPO)"

# Existing file's blob sha is required to update it; absent on first publish.
existing="$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq .sha 2>/dev/null || true)"
[[ "$existing" =~ ^[0-9a-f]{40}$ ]] || existing=""   # 404 on first publish: no sha

args=(
    -X PUT "repos/$TAP_REPO/contents/$CASK_PATH"
    -f message="flash $VERSION"
    -f content="$(printf '%s\n' "$cask" | base64 | tr -d '\n')"
)
[[ -n "$existing" ]] && args+=(-f sha="$existing")

gh api "${args[@]}" --jq '.commit.html_url'
echo "published $CASK_PATH $VERSION to $TAP_REPO"
