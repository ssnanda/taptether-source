#!/usr/bin/env bash
# Platform-only rolling releases; bootstrap current only if no full release exists.
# A future full current release is never modified by platform-only updates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
platform="${1:-}"
case "$platform" in ubuntu|macos|windows) ;; *) echo 'Usage: publish-agent-only.sh ubuntu|macos|windows' >&2; exit 2;; esac
[[ "${GITHUB_REF:-}" == refs/heads/main ]] || { echo 'Agent publishing is restricted to main' >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo 'Not on main' >&2; exit 1; }
version="$(cat VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || { echo 'Invalid agent version' >&2; exit 1; }
repo="ssnanda/taptether.com"
rolling="$platform-current"
display="$platform"
[[ "$platform" == macos ]] && display="macOS"
[[ "$platform" == windows ]] && display="Windows"
[[ "$platform" == ubuntu ]] && display="Ubuntu"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
declare -a files=()
for arch in amd64 arm64; do
  case "$platform" in
    ubuntu)
      source="dist/ubuntu/taptether-agent_${version}_${arch}.deb"
      dest="TapTetherAgent-Ubuntu-$arch.deb"
      ;;
    macos)
      source="dist/macos/TapTetherAgent-macos-$arch-$version.tar.gz"
      dest="TapTetherAgent-macOS-$arch.tar.gz"
      ;;
    windows)
      source="dist/windows/TapTetherAgent-Windows-$arch-$version.zip"
      dest="TapTetherAgent-Windows-$arch.zip"
      ;;
  esac
  [[ -s "$source" ]] || { echo "Missing verified artifact: $source" >&2; exit 1; }
  cp "$source" "$stage/$dest"
  files+=("$stage/$dest")
  if [[ "$platform" == macos ]]; then
    source="dist/macos/TapTetherAgent-macos-$arch-$version.zip"
    dest="TapTetherAgent-macOS-$arch.zip"
    [[ -s "$source" ]] || { echo "Missing verified macOS app: $source" >&2; exit 1; }
    cp "$source" "$stage/$dest"
    files+=("$stage/$dest")
  fi
done
# Reject stale release versions, including when a full release has already
# shipped a later version. Do not mutate any GitHub release on failure.
python3 - "$platform" "$version" <<'PY'
import json, re, sys, urllib.error, urllib.request
platform, version = sys.argv[1:]
valid = re.compile(r'^(\d+)\.(\d+)\.(\d+)\+(\d+)$')
def parts(text):
    match = valid.fullmatch(text)
    if not match: raise SystemExit('Invalid version')
    return tuple(map(int, match.groups()))
wanted = parts(version)
for tag in ('current', platform + '-current'):
    url = f'https://api.github.com/repos/ssnanda/taptether.com/releases/tags/{tag}'
    try:
        req = urllib.request.Request(url, headers={'User-Agent':'TapTether-Agent-Release','Accept':'application/vnd.github+json'})
        with urllib.request.urlopen(req, timeout=15) as response: data = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 404: continue
        raise
    match = re.match(r'^TapTether(?: Ubuntu| macOS| Windows)? (\d+\.\d+\.\d+\+\d+)(?:\s|$)', data.get('name',''))
    if not match: raise SystemExit(f'Unrecognized {tag} release metadata')
    if wanted <= parts(match.group(1)):
        raise SystemExit(f'Refusing {version}: {tag} already has {match.group(1)}')
PY
[[ -n "${GH_TOKEN:-}" ]] || {
  echo 'Set private Actions secret TAPTETHER_PUBLIC_RELEASE_TOKEN with public repo Contents: Read and write.' >&2
  exit 1
}
notes="TapTether ${display} $version — latest ${display} agent installers only.
All application source code and build workflows remain private."
if gh release view "$rolling" -R "$repo" >/dev/null 2>&1; then
  gh release edit "$rolling" -R "$repo" \
    --title "TapTether ${display} $version (agent-only rolling downloads)" \
    --notes "$notes" --latest=false
  gh release upload "$rolling" "${files[@]}" -R "$repo" --clobber
else
  gh release create "$rolling" "${files[@]}" -R "$repo" --target main \
    --title "TapTether ${display} $version (agent-only rolling downloads)" \
    --notes "$notes" --latest=false
fi
# Bootstrap legacy macOS updater clients, which require the full "current"
# channel to exist before they inspect "macos-current". This is a temporary
# agent-only compatibility release until the next coordinated IPA/APK release.
# Never erase assets from a real full current release: older clients validate
# that channel before reading platform-specific releases.
if [[ "$platform" == macos ]]; then
  current_title="$(gh release view current -R "$repo" --json name --jq '.name' 2>/dev/null || true)"
  bootstrap_title="TapTether $version (macOS bootstrap)"
  bootstrap_notes="Temporary macOS agent-only compatibility feed for existing TapTether agents.
This release contains macOS agents only. IPA/APK and other platforms will be
published by the next full release, which replaces this bootstrap channel."
  if [[ -z "$current_title" ]]; then
    gh release create current "${files[@]}" -R "$repo" --target main \
      --title "$bootstrap_title" --notes "$bootstrap_notes" --latest
  elif [[ "$current_title" == *"(macOS bootstrap)" ]]; then
    gh release edit current -R "$repo" \
      --title "$bootstrap_title" --notes "$bootstrap_notes" --latest
    gh release upload current "${files[@]}" -R "$repo" --clobber
  fi
fi
echo "Published latest-only $platform agent $version to public rolling release."
