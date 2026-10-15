#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"
arch="${2:-amd64}"
case "$target" in linux|darwin|windows) ;; *) echo 'Usage: ./bin/2b-tt-agent.sh linux|darwin|windows [amd64|arm64]' >&2;exit 2;;esac
case "$arch" in amd64|arm64) ;; *) echo 'Supported architectures: amd64, arm64' >&2;exit 2;;esac
command -v go >/dev/null 2>&1 || { echo 'Go not installed.' >&2;exit 1; }
version="$(cat "$ROOT/VERSION")"
mkdir -p "$ROOT/dist/agents"
ext=''; [[ "$target" == windows ]] && ext='.exe'
output="$ROOT/dist/agents/TapTetherAgent-${target}-${arch}-${version}${ext}"
if [[ "$target" == darwin ]]; then
  [[ "$(uname -s)" == Darwin ]] || { echo 'Native macOS input requires a macOS build host with Xcode tools.' >&2; exit 1; }
  command -v xcrun >/dev/null || { echo 'Install Xcode Command Line Tools.' >&2; exit 1; }
  (cd "$ROOT/agent" && CGO_ENABLED=1 GOOS=darwin GOARCH="$arch" go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$output" ./cmd/taptether-agent)
  if command -v codesign >/dev/null; then
    codesign --force --sign "${TAPTETHER_CODESIGN_IDENTITY:--}" --timestamp=none "$output"
  fi
else
  (cd "$ROOT/agent" && CGO_ENABLED=0 GOOS="$target" GOARCH="$arch" go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$output" ./cmd/taptether-agent)
fi
echo "Built $output"
