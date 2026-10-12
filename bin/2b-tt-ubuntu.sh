#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/2b-tt-agent.sh" linux amd64
"$ROOT/bin/2b-tt-agent.sh" linux arm64
"$ROOT/bin/2b-tt-deb.sh"
# Retain only this version's two Debian packages and Linux agents locally.
VERSION="$(cat "$ROOT/VERSION")"
for OLD in "$ROOT"/dist/ubuntu/taptether-agent_*.deb; do
  [[ -f "$OLD" ]] || continue
  case "$(basename "$OLD")" in
    "taptether-agent_$VERSION"_"amd64.deb"|"taptether-agent_$VERSION"_"arm64.deb") ;;
    *) rm -f "$OLD" ;;
  esac
done
for OLD in "$ROOT"/dist/agents/TapTetherAgent-linux-*; do
  [[ -f "$OLD" ]] || continue
  case "$(basename "$OLD")" in
    "TapTetherAgent-linux-amd64-$VERSION"|"TapTetherAgent-linux-arm64-$VERSION") ;;
    *) rm -f "$OLD" ;;
  esac
done
