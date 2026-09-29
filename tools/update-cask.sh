#!/usr/bin/env bash
#
# update-cask.sh — render the Homebrew cask for the current release and
# publish it to the tap.
#
#   tools/update-cask.sh --print            # just show the cask
#   tools/update-cask.sh                    # PR it into $TAP_REPO and merge
#
# Version comes from Resources/Info.plist, the sha256 from dist/SHA256SUMS
# (so run tools/release.sh first). The tap's main needs PRs and signed
# commits, and it's shared with the other apps, so this goes the same way
# their bumps do: branch flash-<version> → commit via GraphQL
# createCommitOnBranch (GitHub signs it) → PR "flash <version>" → squash
# merge (GitHub signs that too). Safe to re-run: it reuses the branch/PR and stops if already current.
#
#   TAP_REPO   default sriinnu/homebrew-tap   → brew install --cask sriinnu/tap/flash
#   GH_TOKEN   fine-grained token on TAP_REPO only: Contents + Pull requests
#              read & write (CI: HOMEBREW_TAP_TOKEN)

set -euo pipefail
cd "$(dirname "$0")/.."

die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[1;33m▸ %s\033[0m\n' "$*"; }

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

# Fetch the dmg the way `brew install` will: anonymously. A private source
# repo (or a missing asset) 404s here, and a cask pointing at it would break
# every install. The checksum must match too, or brew refuses it.
url="$(printf '%s\n' "$cask" | sed -n 's/^ *url "\(.*\)"$/\1/p' | sed "s/#{version}/$VERSION/g")"
[[ "$url" == https://* ]] || die "couldn't read the url from $TEMPLATE"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp" "$url" \
    || die "can't download $url anonymously. Is the repo public and the release published?"
got="$(shasum -a 256 "$tmp" | awk '{ print $1 }')"
[[ "$got" == "$SHA256" ]] || die "downloaded dmg sha256 $got ≠ SHA256SUMS $SHA256"

BRANCH="flash-$VERSION"
TITLE="flash $VERSION"
b64() { printf '%s\n' "$cask" | base64 | tr -d '\n'; }

# Already current on main (a re-run after a successful merge)? Nothing to do.
main_b64="$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq .content 2>/dev/null | tr -d '\n' || true)"
if [[ "$main_b64" == "$(b64)" ]]; then
    echo "$TAP_REPO already has flash $VERSION"
    exit 0
fi

# Branch off main, unless a previous run already made it.
if ! gh api "repos/$TAP_REPO/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
    base="$(gh api "repos/$TAP_REPO/git/ref/heads/main" --jq .object.sha)"
    gh api -X POST "repos/$TAP_REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$base" >/dev/null
    say "branch $BRANCH"
fi

# Commit with GraphQL createCommitOnBranch, not the REST contents API: with a
# user token, REST commits come out unsigned, and the tap requires signed
# commits, so the PR could never merge. createCommitOnBranch commits are
# signed by GitHub.
branch_b64="$(gh api "repos/$TAP_REPO/contents/$CASK_PATH?ref=$BRANCH" --jq .content 2>/dev/null | tr -d '\n' || true)"
if [[ "$branch_b64" != "$(b64)" ]]; then
    command -v jq >/dev/null || die "needs jq"
    head="$(gh api "repos/$TAP_REPO/git/ref/heads/$BRANCH" --jq .object.sha)"
    jq -n --arg repo "$TAP_REPO" --arg br "$BRANCH" --arg head "$head" \
          --arg msg "$TITLE" --arg path "$CASK_PATH" --arg c "$(b64)" '{
        query: "mutation($i: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $i) { commit { oid } } }",
        variables: { i: {
            branch: { repositoryNameWithOwner: $repo, branchName: $br },
            expectedHeadOid: $head,
            message: { headline: $msg },
            fileChanges: { additions: [ { path: $path, contents: $c } ] } } } }' \
        | gh api graphql --input - --jq '.data.createCommitOnBranch.commit.oid' >/dev/null
    say "committed $CASK_PATH on $BRANCH (signed by GitHub)"
fi

# Open the PR (or find the one a previous run opened), then squash it in.
pr="$(gh api "repos/$TAP_REPO/pulls?head=${TAP_REPO%%/*}:$BRANCH&state=open" --jq '.[0].number // empty')"
if [[ -z "$pr" ]]; then
    pr="$(gh api -X POST "repos/$TAP_REPO/pulls" \
        -f title="$TITLE" -f head="$BRANCH" -f base=main \
        -f body="Bump cask to $VERSION (sha256 $SHA256). Opened by tools/update-cask.sh." \
        --jq .number)"
fi
say "PR #$pr"
gh api -X PUT "repos/$TAP_REPO/pulls/$pr/merge" -f merge_method=squash >/dev/null \
    || die "couldn't merge $TAP_REPO#$pr — merge it by hand"
gh api -X DELETE "repos/$TAP_REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
echo "published flash $VERSION to $TAP_REPO (#$pr)"
