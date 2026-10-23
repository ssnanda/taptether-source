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
[[ "$(git remote get-url origin)" == *ssnanda/taptether-source* ]] || { echo 'Refusing unknown Git origin.' >&2; exit 1; }
# Full releases must be newer than all independently released desktop agents.
python3 bin/4-guard-release-sync.py
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
  CORE_VERSION="$(cat "$ROOT/INPUT_CORE_VERSION")"
  MAC_CORE="$(printf '%s/dist/macos/TapTetherInputCore-macos-%s-%s.tar.gz' "$ROOT" "$ARCH" "$CORE_VERSION")"
  if [[ -s "$DEB" ]]; then cp "$DEB" "$STAGE/TapTetherAgent-Ubuntu-$ARCH.deb"; fi
  if [[ -s "$MAC" ]]; then cp "$MAC" "$STAGE/TapTetherAgent-macOS-$ARCH.tar.gz"; fi
  if [[ -s "$MAC_APP" ]]; then cp "$MAC_APP" "$STAGE/TapTetherAgent-macOS-$ARCH.zip"; fi
  if [[ -s "$MAC_CORE" ]]; then cp "$MAC_CORE" "$STAGE/TapTetherInputCore-macOS-$ARCH.tar.gz"; fi
  SCREEN_VERSION="$(cat "$ROOT/SCREEN_CORE_VERSION")"
  SCREEN_CORE="$(printf '%s/dist/macos/TapTetherScreenCore-macos-%s-%s.tar.gz' "$ROOT" "$ARCH" "$SCREEN_VERSION")"
  if [[ -s "$SCREEN_CORE" ]]; then cp "$SCREEN_CORE" "$STAGE/TapTetherScreenCore-macOS-$ARCH.tar.gz"; fi
  WIN="$ROOT/dist/windows/TapTetherAgent-Windows-$ARCH-$VERSION.zip"
  if [[ -s "$WIN" ]]; then cp "$WIN" "$STAGE/TapTetherAgent-Windows-$ARCH.zip"; fi
done
if [[ "$HAS_IPA" -eq 1 ]]; then
  python3 "$ROOT/bin/6-tt-generate-altstore.py" \
    --ipa "$STAGE/TapTether.ipa" --version-file "$ROOT/VERSION" \
    --output "$ROOT/altstore.json" --icon-output "$STAGE/TapTether-icon.png"
else
  echo 'No current-version IPA found. Skipping altstore.json refresh.'
fi
# Never call this a successful release with missing or mixed-version assets.
# All eleven files must be produced by the verified agent + mobile jobs.
expected_assets=(
  TapTether-icon.png TapTether.ipa TapTether.apk
  TapTetherAgent-Ubuntu-amd64.deb TapTetherAgent-Ubuntu-arm64.deb
  TapTetherAgent-macOS-amd64.tar.gz TapTetherAgent-macOS-arm64.tar.gz
  TapTetherAgent-macOS-amd64.zip TapTetherAgent-macOS-arm64.zip
  TapTetherInputCore-macOS-amd64.tar.gz TapTetherInputCore-macOS-arm64.tar.gz
  TapTetherScreenCore-macOS-amd64.tar.gz TapTetherScreenCore-macOS-arm64.tar.gz
  TapTetherAgent-Windows-amd64.zip TapTetherAgent-Windows-arm64.zip
)
for asset in "${expected_assets[@]}"; do
  [[ -s "$STAGE/$asset" ]] || {
    echo "Missing required release artifact: $asset" >&2
    exit 1
  }
done
asset_count="$(find "$STAGE" -maxdepth 1 -type f -name 'TapTether*' | wc -l | tr -d ' ')"
[[ "$asset_count" -eq "${#expected_assets[@]}" ]] || {
  echo "Expected exactly ${#expected_assets[@]} TapTether release assets; found $asset_count." >&2
  exit 1
}
# Validation has completed before this release job runs. Remove any extracted
# project-local review bundles so Spotlight sees only the canonical install.
bash "$ROOT/bin/4-clean-macos-review-apps.sh"
# Publish only to a public rolling release; no source SHA or private CI links.
[[ "$REPO" == "ssnanda/taptether.com" ]] || exit 1
[[ -n "${GH_TOKEN:-}" ]] || {
  echo 'Set TAPTETHER_PUBLIC_RELEASE_TOKEN in private Actions secrets; it must have public repo Contents: Read and write.' >&2
  exit 1
}
python3 - "$VERSION" <<'PY'
import json,re,sys,urllib.error,urllib.request
version=sys.argv[1]
def numeric(v):
    m=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)\+(\d+)',v)
    if not m: raise SystemExit('Invalid release version')
    return tuple(map(int,m.groups()))
req=urllib.request.Request('https://api.github.com/repos/ssnanda/taptether.com/releases/tags/current',
    headers={'User-Agent':'TapTether-Release-Guard','Accept':'application/vnd.github+json'})
try:
    with urllib.request.urlopen(req,timeout=15) as f: release=json.load(f)
except urllib.error.HTTPError as e:
    if e.code!=404: raise
else:
    match=re.match(r'^TapTether (\d+\.\d+\.\d+\+\d+)(?:\s|$)',release.get('name',''))
    if not match: raise SystemExit('Unknown current-release version')
    if numeric(version)<=numeric(match.group(1)): raise SystemExit('Refusing older or duplicate release')
PY
NOTES="TapTether $VERSION — latest iOS IPA (unsigned), Android APK, and desktop agents.
The IPA needs a compatible signing/sideloading tool. Only distribution binaries are public."
files=()
for asset in "${expected_assets[@]}"; do files+=("$STAGE/$asset"); done
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release edit "$TAG" -R "$REPO" --title "TapTether $VERSION (rolling downloads)" --notes "$NOTES" --latest
  gh release upload "$TAG" -R "$REPO" --clobber "${files[@]}"
  while IFS=' ' read -r id name; do
    keep=0
    for expected in "${expected_assets[@]}"; do
      if [[ "$name" == "$expected" ]]; then keep=1; break; fi
    done
    if [[ "$keep" -eq 0 ]]; then
      gh api --method DELETE "repos/$REPO/releases/assets/$id" >/dev/null
    fi
  done < <(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | "\(.id) \(.name)"')
else
  gh release create "$TAG" "${files[@]}" -R "$REPO" --target main \
    --title "TapTether $VERSION (rolling downloads)" --notes "$NOTES" --latest
fi
# Synchronized agent binaries supersede older platform-only releases.
for platform in ubuntu macos windows; do
  if gh release view "$platform-current" -R "$REPO" >/dev/null 2>&1; then
    gh release delete "$platform-current" -R "$REPO" --yes --cleanup-tag
  fi
done
# Commit only generated AltStore metadata to public main, never application source.
git fetch --quiet origin main
remote_version="$(git show origin/main:VERSION | tr -d '\r\n')"
if [[ "$remote_version" != "$VERSION" ]]; then
  echo '::warning::Skipping stale AltStore feed because source VERSION advanced.'
  exit 0
fi
feed_sha="$(gh api "repos/$REPO/contents/altstore.json" --jq '.sha' 2>/dev/null || true)"
feed_base64="$(base64 < "$ROOT/altstore.json" | tr -d '\r\n')"
if [[ -n "$feed_sha" ]]; then
  gh api -X PUT "repos/$REPO/contents/altstore.json" \
    -f message="chore: latest AltStore metadata $VERSION" \
    -f content="$feed_base64" -f sha="$feed_sha" -f branch=main >/dev/null
else
  gh api -X PUT "repos/$REPO/contents/altstore.json" \
    -f message="chore: initial AltStore metadata $VERSION" \
    -f content="$feed_base64" -f branch=main >/dev/null
fi
echo "Public current: https://github.com/$REPO/releases/tag/current"
