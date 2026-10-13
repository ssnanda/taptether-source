#!/usr/bin/env python3
"""Contract checks for the four user-triggerable TapTether Actions workflows.

Does not execute builds or publish releases. These lightweight assertions
prevent accidentally removing the release's 1 -> 2 -> 3 dependency.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
workflows = ROOT / ".github" / "workflows"

validation = (workflows / "validate.yml").read_text(encoding="utf-8")
agents = (workflows / "agents.yml").read_text(encoding="utf-8")
release = (workflows / "release.yml").read_text(encoding="utf-8")
publisher = (ROOT / "bin" / "6-tt-publish-latest.sh").read_text(encoding="utf-8")
stage = (ROOT / "bin" / "2e-tt-stage-mobile-agents.sh").read_text(encoding="utf-8")

assert validation.count("workflow_call:") == 1
assert agents.count("workflow_call:") == 1
assert "needs: preflight" in release
assert "uses: ./.github/workflows/validate.yml" in release
assert "needs: validate" in release
assert "uses: ./.github/workflows/agents.yml" in release
assert "needs: agents" in release
assert "name: TapTether-Ubuntu-installers" in release
assert "name: TapTether-macOS-installers" in release
assert "actions/download-artifact@" in release
assert "TAPTETHER_USE_PREBUILT_AGENTS: '1'" in release
assert "TAPTETHER_USE_PREBUILT_AGENTS:-0" in stage
assert "gh release create \"$VERSION_TAG\"" in publisher
assert "--latest=false" in publisher
assert "expected_assets=(" in publisher
assert "already published" in publisher
assert "workflow_dispatch:" in release
assert "release-v0.6.2-request" not in release
print("PASS: release requires current-source validation and verified native agents")
print("PASS: release reuses same-run artifacts and checks all expected packages")
print("PASS: unique-version Latest release is separate from rolling current")
