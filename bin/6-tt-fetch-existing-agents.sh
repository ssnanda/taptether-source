#!/usr/bin/env bash
# Mobile-only IPA: reuse the exact previously published agent binaries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO=ssnanda/taptether.com
command -v gh >/dev/null
[[ -n "${GH_TOKEN:-}" ]] || { echo 'Missing public-release token' >&2; exit 1; }
previous="$(gh release view current -R "$REPO" --json name --jq '.name')"
if [[ ! "$previous" =~ ^TapTether[[:space:]]([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)[[:space:]] ]]; then
  echo 'Existing release version cannot be verified.' >&2
  exit 1
fi
AGENT_VERSION="${BASH_REMATCH[1]}"
APP_VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
[[ "$AGENT_VERSION" != "$APP_VERSION" ]] || {
  echo 'Mobile-only release must have a new app version.' >&2; exit 1;
}
[[ -n "${GITHUB_ENV:-}" ]] && printf 'TAPTETHER_AGENT_PACKAGE_VERSION=%s\n' "$AGENT_VERSION" >> "$GITHUB_ENV"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh release download current -R "$REPO" -D "$TMP" \
  --pattern 'TapTetherAgent-Ubuntu-*.deb' \
  --pattern 'TapTetherAgent-macOS-*.tar.gz' \
  --pattern 'TapTetherScreenCore-macOS-*.tar.gz'
mkdir -p "$ROOT/dist/ubuntu" "$ROOT/dist/macos"
SCREEN_VERSION="$(tr -d '\r\n' < "$ROOT/SCREEN_CORE_VERSION")"
for arch in amd64 arm64; do
  deb="$TMP/TapTetherAgent-Ubuntu-$arch.deb"
  mac="$TMP/TapTetherAgent-macOS-$arch.tar.gz"
  screen="$TMP/TapTetherScreenCore-macOS-$arch.tar.gz"
  for package in "$deb" "$mac" "$screen"; do
    test -s "$package" || { echo "Missing previously published agent artifact: $(basename "$package")" >&2; exit 1; }
  done
  head -c 8 "$deb" | grep -q '!<arch>'
  tar -tzf "$mac" >/dev/null
  tar -tzf "$screen" >/dev/null
  cp "$deb" "$ROOT/dist/ubuntu/taptether-agent_${AGENT_VERSION}_$arch.deb"
  cp "$mac" "$ROOT/dist/macos/TapTetherAgent-macos-$arch-${AGENT_VERSION}.tar.gz"
  cp "$screen" "$ROOT/dist/macos/TapTetherScreenCore-macos-$arch-${SCREEN_VERSION}.tar.gz"
done
# Verify the downloaded asset hashes against GitHub's published SHA-256
# digests when present, never against fabricated app-versioned filenames.
gh api "repos/$REPO/releases/tags/current" > "$TMP/release.json"
python3 - "$TMP" <<'PY'
import hashlib, json, pathlib, sys
folder=pathlib.Path(sys.argv[1])
payload=json.loads((folder/'release.json').read_text())
assets={a['name']:a for a in payload.get('assets',[])}
for file in folder.glob('TapTether*'):
    item=assets[file.name]
    assert item['size']==file.stat().st_size, file.name
    digest=item.get('digest')
    if digest and digest.startswith('sha256:'):
        assert hashlib.sha256(file.read_bytes()).hexdigest()==digest[7:], file.name
print('Verified published desktop agent files (no agent rebuild)')
PY
echo "Reusing agents from $AGENT_VERSION in TapTether app $APP_VERSION"
