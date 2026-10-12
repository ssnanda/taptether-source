#!/usr/bin/env bash
# Explicit update check/installation for installed macOS TapTether LaunchAgent.
set -euo pipefail
MODE="$1"
[[ "$MODE" == check || "$MODE" == update ]] || { echo 'Usage: taptether-agent-update-mac {check|update}' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'Python 3 required' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl required' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS only' >&2; exit 1; }
arch="$(uname -m)"
case "$arch" in x86_64) arch=amd64;; arm64) ;; *) echo "Unsupported Mac: $arch" >&2; exit 1;; esac
bin="$HOME/.local/bin/taptether-agent"
current="$("$bin" --version 2>/dev/null || echo 0.0.0+0)"
info="$(python3 - "$arch" "$current" <<'PY'
import json, re, sys, urllib.request
arch, installed=sys.argv[1:]
req=urllib.request.Request('https://api.github.com/repos/ssnanda/taptether.com/releases/tags/current',
                          headers={'Accept':'application/vnd.github+json','User-Agent':'TapTether-macOS-Updater'})
with urllib.request.urlopen(req,timeout=12) as response: data=json.load(response)
match=re.search(r'(\d+\.\d+\.\d+\+\d+)',data.get('name',''))
if not match: raise SystemExit('Release version not published.')
latest=match.group(1)
def parse(v):
    m=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)\+(\d+)',v)
    if not m: raise SystemExit('Invalid version: '+v)
    return tuple(map(int,m.groups()))
asset=next((a for a in data.get('assets',[]) if a.get('name')=='TapTetherAgent-macOS-'+arch+'.tar.gz'),None)
if not asset: raise SystemExit('macOS installer asset missing')
digest=asset.get('digest','')
if not re.fullmatch(r'sha256:[0-9a-f]{64}',digest): raise SystemExit('No release SHA-256 digest')
url=asset.get('browser_download_url','')
expected=f'https://github.com/ssnanda/taptether.com/releases/download/current/TapTetherAgent-macOS-{arch}.tar.gz'
if url!=expected: raise SystemExit('Unexpected release URL')
print('\t'.join([latest,'yes' if parse(latest)>parse(installed) else 'no',digest[7:],url]))
PY
)"
IFS=$'\t' read -r latest newer digest url <<<"$info"
printf 'TapTether Mac installed: %s | latest published: %s\n' "$current" "$latest"
if [[ "$newer" != yes ]]; then echo 'Already up to date.'; exit 0; fi
if [[ "$MODE" == check ]]; then echo 'Update available. Run taptetherctl-mac update.'; exit 0; fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/mac-agent.tar.gz"
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 12 --max-time 180 --retry 2 "$url" -o "$archive"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$digest" ]] || { echo 'SHA-256 mismatch; aborting' >&2; exit 1; }
# Permit only the three expected installer members. Never extract arbitrary paths from downloads.
members="$(tar -tzf "$archive" | sort)"
[[ "$members" ==  ]] || { echo 'Unexpected archive files; aborting' >&2; exit 1; }
tar -xzf "$archive" -C "$tmp"
chmod 700 "$tmp/taptetherctl-mac"
chmod 755 "$tmp/taptether-agent"
echo "Verified macOS archive SHA-256. Installing $latest..."
"$tmp/taptetherctl-mac" install
TapTether.icns\ntaptether-agent\ntaptether-agent-update-mac\ntaptetherctl-mac' ]] || { echo 'Unexpected archive files; aborting' >&2; exit 1; }
tar -xzf "$archive" -C "$tmp"
chmod 700 "$tmp/taptetherctl-mac"
chmod 755 "$tmp/taptether-agent"
echo "Verified macOS archive SHA-256. Installing $latest..."
"$tmp/taptetherctl-mac" install
