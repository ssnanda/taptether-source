#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Native macOS agent builds require macOS with Xcode tools.' >&2; exit 1; }
version="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/macos"
for arch in amd64 arm64; do
  "$ROOT/bin/2b-tt-agent.sh" darwin "$arch"
  temp="$(mktemp -d)"
  cp "$ROOT/dist/agents/TapTetherAgent-darwin-$arch-$version" "$temp/taptether-agent"
  cp "$ROOT/bin/4-macos-agent-setup.sh" "$temp/taptetherctl-mac"
  chmod +x "$temp/taptether-agent" "$temp/taptetherctl-mac"
  out="$ROOT/dist/macos/TapTetherAgent-macos-$arch-$version.tar.gz"
  COPYFILE_DISABLE=1 tar -czf "$out" -C "$temp" taptether-agent taptetherctl-mac
  rm -rf "$temp"
  echo "macOS installer archive: $out"
done
