#!/usr/bin/env python3
"""Static checks for TapTether's *single* manual GitHub Actions workflow."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
folder = ROOT / ".github" / "workflows"
workflow_files = sorted(folder.glob("*.yml")) + sorted(folder.glob("*.yaml"))
assert len(workflow_files) == 1 and workflow_files[0].name == "release.yml", (
    "Expected exactly one maintained Actions workflow: release.yml"
)

workflow = workflow_files[0].read_text(encoding="utf-8")
publisher = (ROOT / "bin" / "6-tt-publish-latest.sh").read_text(encoding="utf-8")
stage = (ROOT / "bin" / "2e-tt-stage-mobile-agents.sh").read_text(encoding="utf-8")

assert "workflow_dispatch:" in workflow
assert "schedule:" in workflow
assert "task:" in workflow
assert all(f"- {mode}" in workflow for mode in ("release", "validate", "cleanup"))
assert "\n  push:" not in workflow, "Ordinary pushes must not trigger builds"

assert "  validate:" in workflow
assert "  build-ubuntu:" in workflow
assert "    needs: validate" in workflow
assert "  build-and-publish:" in workflow
assert "    needs: build-ubuntu" in workflow
assert "run: bash bin/2b-tt-ubuntu.sh" in workflow
assert "run: bash bin/2b-tt-macos.sh" in workflow
assert "run: bash bin/2a-tt-ipa.sh --no-publish" in workflow
assert "run: bash bin/2a-tt-apk.sh --no-publish" in workflow
assert "run: bash bin/6-tt-publish-latest.sh" in workflow

assert "name: TapTether-Ubuntu-installers" in workflow
assert "actions/download-artifact@" in workflow
assert "TAPTETHER_USE_PREBUILT_AGENTS: '1'" in workflow
assert "TAPTETHER_USE_PREBUILT_AGENTS:-0" in stage
assert "gh release create \"$VERSION_TAG\"" in publisher
assert "--latest=false" in publisher
assert "expected_assets=(" in publisher
assert "already published" in publisher
assert "release-v0.6.2-request" not in workflow

assert "  cleanup-history:" in workflow
assert "    needs: build-and-publish" in workflow
assert "always() && (github.event_name == 'schedule'" in workflow
assert "inputs.task == 'cleanup'" in workflow
assert "needs.build-and-publish.result == 'success'" in workflow

print("PASS: exactly one Actions workflow, manually selectable release/validate/cleanup")
print("PASS: validate -> native agents -> IPA/APK -> publish, with same-run artifacts")
print("PASS: weekly cleanup and immutable version-tagged Latest releases")
