#!/usr/bin/env bash
#
# verify-release-tag.sh <tag> — is this tag allowed to ship?
#
# The tag must be signed by a key in .github/allowed_signers, sit on main's
# history, and be what's checked out. The signers file is read from main, not
# from the tag, so a tag can't bring its own key, and every key in it must be
# pinned here. A stolen token can push a tag; it can't sign one.
#
# Runs in CI before any secret is in reach, and again in release.sh --publish.

set -euo pipefail

die() { printf '✗ %s\n' "$*" >&2; exit 1; }

TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z.]+)?$ ]] || die "not a release tag: $TAG"

# Titan security key, Secure Enclave. Change these together with allowed_signers.
RELEASE_KEY_FINGERPRINTS="SHA256:jWV8C3RG95sm64vjVhs1vQj48aFBAsgmlPsCm/5zezw SHA256:L01yveJ19ozoWLKZfrgeyft/VqmKka1xF/qZ8o7Z+CM"

REF="refs/tags/$TAG"

# From origin, not the local ref: that's what ships, and actions/checkout can
# strip an annotated tag down to a lightweight one, signature and all.
git fetch --no-tags --quiet --force origin "+$REF:$REF" "+refs/heads/main:refs/remotes/origin/main" \
    || die "couldn't fetch $TAG and main from origin"
[[ "$(git cat-file -t "$REF" 2>/dev/null)" == "tag" ]] || die "$TAG isn't an annotated tag"

SIGNERS="$(mktemp)"
trap 'rm -f "$SIGNERS"' EXIT
git show origin/main:.github/allowed_signers > "$SIGNERS"

# `|| [[ -n ... ]]` keeps a last line with no trailing newline: verify-tag
# would still trust it, so it has to be checked too.
while read -r principal keytype key _comment || [[ -n "${principal:-}" ]]; do
    [[ -z "$principal" || "$principal" == \#* ]] && continue
    fpr="$(printf '%s %s\n' "$keytype" "$key" | ssh-keygen -E sha256 -lf - | awk '{print $2}')"
    [[ " $RELEASE_KEY_FINGERPRINTS " == *" $fpr "* ]] \
        || die "allowed_signers on main has a key that isn't pinned here: $fpr"
done < "$SIGNERS"

git -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen \
    -c gpg.ssh.allowedSignersFile="$SIGNERS" verify-tag "$REF" \
    || die "$TAG isn't signed by a key in .github/allowed_signers on main"

git merge-base --is-ancestor "$REF^{commit}" origin/main \
    || die "$TAG doesn't point at a commit on main"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$REF^{commit}")" ]] \
    || die "HEAD isn't the commit $TAG points at — check out the tag"

echo "✓ $TAG is signed by a release key, on main, and checked out"
