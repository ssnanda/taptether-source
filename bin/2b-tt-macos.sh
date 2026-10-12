#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Native macOS agent builds require macOS with Xcode tools.' >&2; exit 1; }
version="$(cat "$ROOT/VERSION")"
python3 "$ROOT/bin/9-tt-brand-icons.py"
mkdir -p "$ROOT/dist/macos"
for arch in amd64 arm64; do
  "$ROOT/bin/2b-tt-agent.sh" darwin "$arch"
  temp="$(mktemp -d)"
  cp "$ROOT/dist/agents/TapTetherAgent-darwin-$arch-$version" "$temp/taptether-agent"
  cp "$ROOT/bin/4-macos-agent-setup.sh" "$temp/taptetherctl-mac"
  cp "$ROOT/bin/8-tt-update-macos.sh" "$temp/taptether-agent-update-mac"
  chmod +x "$temp/taptether-agent" "$temp/taptetherctl-mac" "$temp/taptether-agent-update-mac"
  out="$ROOT/dist/macos/TapTetherAgent-macos-$arch-$version.tar.gz"
  COPYFILE_DISABLE=1 tar -czf "$out" -C "$temp" taptether-agent taptetherctl-mac taptether-agent-update-mac
  rm -rf "$temp"
  echo "macOS installer archive: $out"
done
# Retain only this version's macOS archives and binaries locally.
for OLD in "$ROOT"/dist/macos/TapTetherAgent-macos-*.tar.gz; do
  [[ -f "$OLD" ]] || continue
  case "$(basename "$OLD")" in
    "TapTetherAgent-macos-amd64-$version.tar.gz"|"TapTetherAgent-macos-arm64-$version.tar.gz") ;;
    *) rm -f "$OLD" ;;
  esac
done
for OLD in "$ROOT"/dist/agents/TapTetherAgent-darwin-*; do
  [[ -f "$OLD" ]] || continue
  case "$(basename "$OLD")" in
    "TapTetherAgent-darwin-amd64-$version"|"TapTetherAgent-darwin-arm64-$version") ;;
    *) rm -f "$OLD" ;;
  esac
done
