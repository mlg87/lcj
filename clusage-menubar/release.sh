#!/usr/bin/env bash
# release.sh — tag, build, and publish a GitHub release for clusage-menubar.
#
# Run manually from the clusage-menubar/ directory AFTER the PR has merged to main.
# Guards refuse to run from a dirty tree, a non-main branch, or when the tag exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(cat VERSION)"
TAG="clusage-menubar-v${VERSION}"
DMG="ClusageMenubar-${VERSION}.dmg"

echo "==> clusage-menubar release ${TAG}"

# -- Guards --

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree is dirty — commit or stash changes before releasing" >&2
    exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "ERROR: must be on main branch (currently on '${CURRENT_BRANCH}')" >&2
    exit 1
fi

echo "--> Fetching origin …"
git fetch origin

LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse origin/main)"
if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
    echo "ERROR: HEAD (${LOCAL_HEAD:0:7}) != origin/main (${REMOTE_HEAD:0:7}) — pull first" >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: tag '${TAG}' already exists — bump VERSION before releasing" >&2
    exit 1
fi

# -- Extract CHANGELOG section --

NOTES="$(awk "/^## v${VERSION}$/{found=1; next} found && /^## v/{exit} found{print}" CHANGELOG.md)"
if [[ -z "$NOTES" ]]; then
    echo "ERROR: no '## v${VERSION}' section found in CHANGELOG.md — add release notes first" >&2
    exit 1
fi

echo "--> Release notes:"
echo "$NOTES" | head -20
echo ""

# -- Build --

echo "--> Building app …"
./build.sh

echo "--> Creating DMG …"
./create_dmg.sh

if [[ ! -f "$DMG" ]]; then
    echo "ERROR: expected DMG not found: $DMG" >&2
    exit 1
fi

# -- Tag --

echo "--> Tagging ${TAG} …"
git tag -a "$TAG" -m "clusage-menubar v${VERSION}"
git push origin "$TAG"

# -- GitHub release --

echo "--> Creating GitHub release …"
gh release create "$TAG" "$DMG" \
    --title "clusage-menubar v${VERSION}" \
    --notes "$NOTES"

echo ""
echo "==> Released: ${TAG}"
echo "    DMG: ${DMG}"
