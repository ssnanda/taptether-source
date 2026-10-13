#!/usr/bin/env bash
# Publish only the current version's IPA, APK and agent installers to one rolling release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO=ssnanda/taptether.com
TAG=current
VERSION="$(cat VERSION)"
STAGE="$ROOT/dist/release"
command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI is required: brew install gh; gh auth login' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 required' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Sign in with gh auth login (or set GH_TOKEN in CI)' >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo 'Publish only from main.' >&2; exit 1; }
[[ "$(git remote get-url origin)" == *ssnanda/taptether.com* ]] || { echo 'Refusing unknown Git origin.' >&2; exit 1; }
mkdir -p "$STAGE"
# The stable release folder never retains earlier versions.
find "$STAGE" -maxdepth 1 -type f -name 'TapTether*' -delete
IPA="$ROOT/dist/ios/TapTether-$VERSION-unsigned.ipa"
if [[ -s "$ROOT/dist/ios/TapTether-$VERSION.ipa" ]]; then
  IPA="$ROOT/dist/ios/TapTether-$VERSION.ipa"
fi
HAS_IPA=0
if [[ -s "$IPA" ]]; then
  cp "$IPA" "$STAGE/TapTether.ipa"
  HAS_IPA=1
fi
APK="$ROOT/dist/android/TapTether-$VERSION.apk"
if [[ -s "$APK" ]]; then cp "$APK" "$STAGE/TapTether.apk"; fi
for ARCH in amd64 arm64; do
  DEB="$(printf '%s/dist/ubuntu/taptether-agent_%s_%s.deb' "$ROOT" "$VERSION" "$ARCH")"
  MAC="$(printf '%s/dist/macos/TapTetherAgent-macos-%s-%s.tar.gz' "$ROOT" "$ARCH" "$VERSION")"
  MAC_APP="$(printf '%s/dist/macos/TapTetherAgent-macos-%s-%s.zip' "$ROOT" "$ARCH" "$VERSION")"
  if [[ -s "$DEB" ]]; then cp "$DEB" "$STAGE/TapTetherAgent-Ubuntu-$ARCH.deb"; fi
  if [[ -s "$MAC" ]]; then cp "$MAC" "$STAGE/TapTetherAgent-macOS-$ARCH.tar.gz"; fi
  if [[ -s "$MAC_APP" ]]; then cp "$MAC_APP" "$STAGE/TapTetherAgent-macOS-$ARCH.zip"; fi
done
if [[ "$HAS_IPA" -eq 1 ]]; then
  python3 "$ROOT/bin/6-tt-generate-altstore.py" \
    --ipa "$STAGE/TapTether.ipa" --version-file "$ROOT/VERSION" \
    --output "$ROOT/altstore.json" --icon-output "$STAGE/TapTether-icon.png"
else
  echo 'No current-version IPA found. Skipping altstore.json refresh.'
fi
shopt -s nullglob
ASSET_COUNT="$(find "$STAGE" -maxdepth 1 -type f -name 'TapTether*' | wc -l | tr -d ' ')"
[[ "$ASSET_COUNT" -gt 0 ]] || { echo 'No current-version build artifacts. Build IPA/APK/agents before publishing.' >&2; exit 1; }
NOTES="TapTether $VERSION — current build. The single rolling release replaces prior binaries. Unsigned iOS IPA requires AltStore signing."
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release edit "$TAG" -R "$REPO" --title "TapTether $VERSION (current)" --notes "$NOTES" --latest
else
  gh release create "$TAG" -R "$REPO" --target main --title "TapTether $VERSION (current)" --notes "$NOTES" --latest
fi
# Remove only TapTether-managed assets before replacing them, including stale platforms.
while IFS=' ' read -r ID NAME; do
  if [[ "$NAME" == TapTether* ]]; then
    gh api --method DELETE "repos/$REPO/releases/assets/$ID" >/dev/null
  fi
done < <(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | "\(.id) \(.name)"')
(cd "$STAGE" && gh release upload "$TAG" -R "$REPO" TapTether*)
echo "Uploaded $ASSET_COUNT current TapTether files to https://github.com/$REPO/releases/tag/$TAG"
# Only commit a valid feed after its corresponding IPA is actually uploaded.
if [[ "$HAS_IPA" -eq 1 ]]; then
  git add -- altstore.json
  if ! git diff --cached --quiet -- altstore.json; then
    git -c user.name='TapTether Release Bot' -c user.email='actions@users.noreply.github.com' commit -m "chore: publish AltStore feed for $VERSION" -- altstore.json
    git push origin HEAD:main
    echo 'Committed and pushed altstore.json with the published IPA size/version.'
  fi
fi
echo 'Note: private GitHub release assets and raw altstore.json are not anonymously accessible to AltStore.'
