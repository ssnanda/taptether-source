#!/usr/bin/env bash
# Explicitly check or update the Ubuntu agent using published GitHub Release SHA-256 digests.
set -euo pipefail
MODE="$1"
[[ "$MODE" == check || "$MODE" == update ]] || { echo 'Usage: taptether-agent-update {check|update}' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'Python 3 required' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl required' >&2; exit 1; }
arch="$(dpkg --print-architecture)"
case "$arch" in amd64|arm64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
current="$(dpkg-query -W taptether-agent 2>/dev/null | awk '{print $2}')"
current="${current:-0.0.0+0}"
asset="TapTetherAgent-Ubuntu-$arch.deb"
info="$(python3 - "$arch" "$current" <<'PY'
import json, re, sys, urllib.request
arch, installed = sys.argv[1:]
req = urllib.request.Request('https://api.github.com/repos/ssnanda/taptether.com/releases/tags/current',
    headers={'Accept':'application/vnd.github+json','User-Agent':'TapTether-Ubuntu-Updater'})
with urllib.request.urlopen(req, timeout=12) as response: data=json.load(response)
match=re.search(r'(\d+\.\d+\.\d+\+\d+)', data.get('name',''))
if not match: raise SystemExit('Release version unavailable; refusing upgrade.')
latest=match.group(1)
def parse(s):
    m=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)\+(\d+)',s)
    if not m: raise SystemExit('Cannot compare versions: '+s)
    return tuple(map(int,m.groups()))
asset=next((a for a in data.get('assets',[]) if a.get('name')=='TapTetherAgent-Ubuntu-'+arch+'.deb'),None)
if not asset: raise SystemExit('Release missing required Ubuntu installer.')
digest=asset.get('digest','')
if not re.fullmatch('sha256:[0-9a-f]{64}',digest):
    raise SystemExit('GitHub asset SHA-256 digest absent: refusing upgrade.')
url=asset.get('browser_download_url','')
expected=f'https://github.com/ssnanda/taptether.com/releases/download/current/TapTetherAgent-Ubuntu-{arch}.deb'
if url!=expected: raise SystemExit('Unexpected release URL: refusing download.')
print('\t'.join([latest,'yes' if parse(latest)>parse(installed) else 'no',digest[7:],url]))
PY
)"
IFS=$'\t' read -r latest newer digest url <<<"$info"
printf 'TapTether Ubuntu installed: %s | latest published: %s\n' "$current" "$latest"
if [[ "$newer" != yes ]]; then echo 'Already up to date.'; exit 0; fi
if [[ "$MODE" == check ]]; then echo 'Update available. Run: ~/.local/bin/taptetherctl update'; exit 0; fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pkg="$tmp/taptether-agent.deb"
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 12 --max-time 180 --retry 2 "$url" -o "$pkg"
printf '%s  %s\n' "$digest" "$pkg" | sha256sum --check --status || { echo 'SHA-256 mismatch; refusing install.' >&2; exit 1; }
[[ "$(dpkg-deb --field "$pkg" Package)" == taptether-agent ]] || { echo 'Unexpected package name.' >&2; exit 1; }
[[ "$(dpkg-deb --field "$pkg" Version)" == "$latest" ]] || { echo 'Version mismatch.' >&2; exit 1; }
[[ "$(dpkg-deb --field "$pkg" Architecture)" == "$arch" ]] || { echo 'Architecture mismatch.' >&2; exit 1; }
echo "Verified $asset against the release SHA-256 digest."
sudo apt install -y "$pkg"
sudo systemctl restart taptether-agent.service
sudo systemctl is-active --quiet taptether-agent.service
echo "Upgraded and restarted: $latest. Existing pairing identity was preserved."
