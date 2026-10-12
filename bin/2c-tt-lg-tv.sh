#!/usr/bin/env bash
# Package the TapTether LG webOS companion. Requires LG's supported webOS CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v ares-package >/dev/null 2>&1 || {
  echo 'LG webOS CLI not installed. Install current webOS CLI from LG, then rerun this script.' >&2
  echo 'This is a companion proof of concept, not a system-wide TV remote agent.' >&2
  exit 2
}
python3 "$ROOT/bin/9-tt-brand-icons.py"
mkdir -p "$ROOT/dist/lg-webos"
ares-package -o "$ROOT/dist/lg-webos" "$ROOT/tv/lg-webos"
echo 'LG webOS companion .ipk saved in dist/lg-webos/. Use LG Developer Mode / ares-install.'
