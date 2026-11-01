#!/usr/bin/env bash
# Publish only iPhone IPA; preserve existing APK, macOS, Ubuntu and Windows agents.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO=ssnanda/taptether.com
TAG=current
VERSION="$(tr -d '\r\n' < VERSION)"
[[ "$(git branch --show-current)" == main ]] || { echo 'Publish from main only.' >&2; exit 1; }
[[ -n "${GH_TOKEN:-}" ]] || { echo 'Public release token required.' >&2; exit 1; }
command -v gh >/dev/null
STAGE="$ROOT/dist/release"
mkdir -p "$STAGE"
IPA="$ROOT/dist/ios/TapTether-$VERSION-unsigned.ipa"
[[ -s "$IPA" ]] || {
  echo 'Validated current-version IPA missing.' >&2; exit 1;
}
cp "$IPA" "$STAGE/TapTether.ipa"
python3 bin/6-tt-generate-altstore.py \
  --ipa "$STAGE/TapTether.ipa" --version-file VERSION \
  --output altstore.json --icon-output "$STAGE/TapTether-icon.png"
gh api "repos/$REPO/releases/tags/$TAG" > "$STAGE/prior-release.json"
python3 - "$VERSION" "$STAGE/prior-release.json" <<'PY'
import json,re,sys
version=sys.argv[1]
payload=json.load(open(sys.argv[2]))
match=re.fullmatch(r'TapTether (\d+\.\d+\.\d+\+\d+) \(rolling downloads\)',payload['name'])
if not match: raise SystemExit('Unknown public current release version')
def parts(s): return tuple(map(int,re.fullmatch(r'(\d+)\.(\d+)\.(\d+)\+(\d+)',s).groups()))
if parts(version) <= parts(match.group(1)): raise SystemExit('Refusing older/duplicate app release')
assets={a['name']:a for a in payload['assets']}
agent_names=[name for name in assets if name.startswith(('TapTetherAgent-', 'TapTetherInputCore-', 'TapTetherScreenCore-'))]
if len(agent_names)!=12: raise SystemExit('Expected 12 unchanged desktop agent/core assets')
if any(assets[name]['size']<1000 for name in agent_names):
    raise SystemExit('Existing desktop agent asset is empty')
if assets.get('TapTether.apk', {}).get('size',0)<1000000:
    raise SystemExit('Existing Android APK is missing or empty')
print('Retaining',len(agent_names),'desktop packages and the existing Android APK')
PY
# Only the IPA and icon are replaced. Verify APK plus every agent asset
# remains byte-for-byte identical by checking GitHub asset IDs and digests.
previous_assets="$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | select(.name == "TapTether.apk" or (.name | startswith("TapTetherAgent-") or startswith("TapTetherInputCore-") or startswith("TapTetherScreenCore-"))) | "\(.name):\(.id):\(.size):\(.digest)"' | sort)"
gh release upload "$TAG" -R "$REPO" --clobber \
  "$STAGE/TapTether.ipa" "$STAGE/TapTether-icon.png"
remaining_assets="$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | select(.name == "TapTether.apk" or (.name | startswith("TapTetherAgent-") or startswith("TapTetherInputCore-") or startswith("TapTetherScreenCore-"))) | "\(.name):\(.id):\(.size):\(.digest)"' | sort)"
[[ "$previous_assets" == "$remaining_assets" ]] || {
  echo 'The existing APK or agent files unexpectedly changed.' >&2; exit 1;
}
gh release edit "$TAG" -R "$REPO" \
  --title "TapTether $VERSION (rolling downloads)" \
  --notes "TapTether $VERSION iPhone-only update (unsigned IPA). The existing Android APK and desktop agents are unchanged. iOS IPA requires signing." \
  --latest
# Update only public AltStore metadata, not private code or desktop releases.
feed_sha="$(gh api "repos/$REPO/contents/altstore.json" --jq '.sha')"
feed_content="$(base64 < altstore.json | tr -d '\r\n')"
gh api -X PUT "repos/$REPO/contents/altstore.json" \
  -f message="chore: current AltStore metadata $VERSION" \
  -f content="$feed_content" -f sha="$feed_sha" -f branch=main >/dev/null
test "$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.name')" = "TapTether $VERSION (rolling downloads)"
test "$(gh api "repos/$REPO/contents/altstore.json" --jq '.sha')" = "$(git hash-object altstore.json)"
gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | select(.name=="TapTether.ipa") | select(.size>1000000) | .name' | grep -qx 'TapTether.ipa'
echo "Verified iPhone-only release $VERSION with unchanged APK and agents"
