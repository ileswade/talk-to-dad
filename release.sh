#!/bin/zsh
# Publish a new version of Talk to Dad. Dad's Mac installs it automatically (within 6 hours,
# or right away from TTD Family → "Update Dad's Mac").
#   ./release.sh 0.5 "What changed"
set -e
cd "${0:A:h}"
[ $# -eq 2 ] || { echo "usage: ./release.sh <version> \"<notes>\""; exit 1; }
VERSION=$1; NOTES=$2
echo "$VERSION" > VERSION
./build-app.sh
swift tools/sign-update.swift dist/Talk-to-Dad.zip > dist/Talk-to-Dad.zip.sig
git add -A
git commit -q -m "Talk to Dad $VERSION: $NOTES

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag "v$VERSION"
git push -q origin main "v$VERSION"
gh release create "v$VERSION" dist/Talk-to-Dad.dmg dist/Talk-to-Dad.zip dist/Talk-to-Dad.zip.sig dist/TTD-Family.zip \
  --title "Talk to Dad $VERSION" --notes "$NOTES

**Talk-to-Dad.dmg**: first install on the parent's Mac. **Talk-to-Dad.zip + .sig**: signed automatic update. **TTD-Family.zip**: the family app."
echo "Released $VERSION"
