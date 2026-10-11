#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v ar >/dev/null 2>&1 || { echo 'ar required to package .deb' >&2;exit 1; }
command -v tar >/dev/null 2>&1 || { echo 'tar required to package .deb' >&2;exit 1; }
version="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/ubuntu"
for arch in amd64 arm64; do
  binary="$ROOT/dist/agents/TapTetherAgent-linux-${arch}-${version}"
  [[ -f "$binary" ]] || { echo "Missing $binary; run ./bin/2b-tt-ubuntu.sh first" >&2;exit 1; }
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/control" "$tmp/data/usr/local/bin"
  cp "$binary" "$tmp/data/usr/local/bin/taptether-agent"
  chmod 755 "$tmp/data/usr/local/bin/taptether-agent"
  cat >"$tmp/control/control" <<EOF
Package: taptether-agent
Version: ${version}
Section: utils
Priority: optional
Architecture: ${arch}
Maintainer: TapTether <support@taptether.com>
Depends: xdotool
Description: TapTether local-first keyboard and trackpad agent
 A local HTTPS remote input agent for an X11 Ubuntu desktop.
 No cloud account or telemetry.
EOF
  printf '2.0\n' >"$tmp/debian-binary"
  (cd "$tmp/control" && tar -czf "$tmp/control.tar.gz" control)
  (cd "$tmp/data" && tar -czf "$tmp/data.tar.gz" usr)
  output="$ROOT/dist/ubuntu/taptether-agent_${version}_${arch}.deb"
  rm -f "$output"
  (cd "$tmp" && ar rcs "$output" debian-binary control.tar.gz data.tar.gz)
  rm -rf "$tmp"
  echo "Debian package: $output"
done
