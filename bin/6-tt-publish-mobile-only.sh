#!/usr/bin/env bash
# Publish only IPA/APK/icon; preserve working macOS, Ubuntu, Windows agents.
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
[[ -s "$IPA" ]] && [[ -s "$ROOT/dist/android/TapTether-$VERSION.apk" ]] || {
  echo 'Validated current-version mobile artifacts missing.' >&2; exit 1;
}
cp "$IPA" "$STAGE/TapTether.ipa"
cp "$ROOT/dist/android/TapTether-$VERSION.apk" "$STAGE/TapTether.apk"
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
print('Retaining',len(agent_names),'verified previously published desktop packages')
PY
before_agents="$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | select(.name | startswith("TapTetherAgent-") or startswith("TapTetherInputCore-") or startswith("TapTetherScreenCore-")) | "\(.name):\(.id):\(.size):\(.digest)"' | sort)"
gh release upload "$TAG" -R "$REPO" --clobber \
  "$STAGE/TapTether.ipa" "$STAGE/TapTether.apk" "$STAGE/TapTether-icon.png"
after_agents="$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | select(.name | startswith("TapTetherAgent-") or startswith("TapTetherInputCore-") or startswith("TapTetherScreenCore-")) | "\(.name):\(.id):\(.size):\(.digest)"' | sort)"
[[ "$before_agents" == "$after_agents" ]] || {
  echo 'Agent artifacts unexpectedly changed; check release before proceeding.' >&2; exit 1;
}
gh release edit "$TAG" -R "$REPO" \
  --title "TapTether $VERSION (rolling downloads)" \
  --notes "TapTether $VERSION mobile update (unsigned IPA and Android APK). Existing macOS, Ubuntu, Windows agents are unchanged. iOS IPA requires signing." \
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
echo "Verified mobile-only public release $VERSION and unchanged agents"
