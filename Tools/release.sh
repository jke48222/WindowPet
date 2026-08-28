#!/bin/bash
# One command to cut a release, with the checks that stop a bad one going out.
#
#   bash Tools/release.sh 1.2.0            dry run: check everything, build nothing public
#   bash Tools/release.sh 1.2.0 --publish  notarize, tag, and publish to GitHub
#
# The dry run is the default on purpose. Publishing is the one step here that
# cannot be taken back, so it has to be asked for.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
PUBLISH=0
[ "${2:-}" = "--publish" ] && PUBLISH=1
if [ -z "$VERSION" ]; then
  echo "Usage: bash Tools/release.sh <version> [--publish]"
  exit 2
fi
TAG="v$VERSION"
FAIL=0
note() { printf '  %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; FAIL=1; }

echo "Preflight for $TAG"

# 1. The version in the bundle has to be the version being tagged, or the
#    download and the release notes disagree about what this is.
PLIST_VERSION=$(grep -A1 CFBundleShortVersionString Tools/make-app.sh \
  | grep -o '<string>[0-9.]*</string>' | head -1 | tr -d '<>a-z/' || true)
if [ "$PLIST_VERSION" = "$VERSION" ]; then
  note "Info.plist version is $VERSION"
else
  bad "Info.plist says '$PLIST_VERSION' but you asked to release '$VERSION'"
fi

# 2. Release notes for this version must exist. A release with no notes is a
#    file with a number on it.
if grep -q "^## $VERSION" CHANGELOG.md; then
  note "CHANGELOG has a section for $VERSION"
else
  bad "CHANGELOG.md has no '## $VERSION' section"
fi

# 3. Nothing uncommitted, or the tag points at something that is not what was
#    built and tested.
if [ -z "$(git status --porcelain)" ]; then
  note "working tree is clean"
else
  bad "uncommitted changes; commit or stash before releasing"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  bad "$TAG already exists"
else
  note "$TAG is free"
fi

# 4. Tests and the end to end rig. The rig needs a quiet machine: its window
#    choreography times out under load, which looks exactly like a regression.
echo "Running tests"
if swift test >/dev/null 2>&1; then
  note "unit tests pass"
else
  bad "unit tests failed; run 'swift test' to see it"
fi

LOAD=$(uptime | sed -E 's/.*load averages?: ([0-9.]+).*/\1/' | cut -d. -f1)
if [ "${LOAD:-9}" -ge 3 ]; then
  bad "load average is $LOAD; the rig needs a quiet machine to be meaningful"
else
  note "machine is quiet (load $LOAD)"
fi

# 5. Signing and notarization. These are the two only a person can set up.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
  note "Developer ID: $IDENTITY"
else
  bad "no Developer ID Application certificate. Create one at developer.apple.com
        (Certificates, Identifiers and Profiles, Certificates, plus, Developer ID
        Application), download it, and double click to install it."
fi

if xcrun notarytool history --keychain-profile "windowpet" >/dev/null 2>&1; then
  note "notary credentials stored"
else
  bad "no stored notary credentials. Run once, with an app-specific password
        from appleid.apple.com:
          xcrun notarytool store-credentials \"windowpet\" \\
            --apple-id <your-apple-id> --team-id PK389W6V96"
fi

if [ "$FAIL" = "1" ]; then
  echo
  echo "Not ready. Nothing was built or published."
  exit 1
fi

echo "Preflight passed."
if [ "$PUBLISH" = "0" ]; then
  echo "Dry run. Rerun with --publish to notarize, tag and publish."
  exit 0
fi

echo "Building, signing and notarizing"
bash Tools/make-dist.sh --notarize

echo "Tagging $TAG"
git tag -a "$TAG" -m "WindowPet $VERSION"
git push origin main --follow-tags

echo "Publishing the GitHub release"
# The notes are the CHANGELOG section for this version, nothing else.
awk -v v="## $VERSION" '$0 ~ "^"v {found=1; next} found && /^## / {exit} found' \
  CHANGELOG.md > build/release-notes.md
gh release create "$TAG" build/WindowPet.dmg \
  --title "WindowPet $VERSION" --notes-file build/release-notes.md
echo "Released $TAG"
