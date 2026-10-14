#!/usr/bin/env python3
"""Static checks for TapTether's single gated automatic/manual workflow."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
folder = ROOT / ".github" / "workflows"
workflow_files = sorted(folder.glob("*.yml")) + sorted(folder.glob("*.yaml"))
assert len(workflow_files) == 1 and workflow_files[0].name == "taptether.yml", (
    "Expected exactly one maintained Actions workflow: taptether.yml"
)

workflow = workflow_files[0].read_text(encoding="utf-8")
publisher = (ROOT / "bin" / "6-tt-publish-latest.sh").read_text(encoding="utf-8")
stage = (ROOT / "bin" / "2e-tt-stage-mobile-agents.sh").read_text(encoding="utf-8")

assert "workflow_dispatch:" in workflow
assert "schedule:" in workflow
assert "task:" in workflow
assert all(f"- {mode}" in workflow for mode in ("release", "build", "validate"))
assert "          - cleanup" not in workflow
assert "  push:\n    branches: [main]" in workflow, (
    "Auto-release only from main"
)
assert "    paths:\n      - VERSION" in workflow, (
    "Automatically run releases only for explicit VERSION changes"
)
assert "github.event_name == 'push' || inputs.task == 'release'" in workflow

assert "  validate:" in workflow
assert "  build-ubuntu:" in workflow
assert "    needs: validate" in workflow
assert "github.event_name == 'push' || inputs.task == 'release' || inputs.task == 'build'" in workflow
assert "  build-and-publish:" in workflow
assert "    needs: build-ubuntu" in workflow
# All scripts invoked directly by a release build must have an executable
# Git mode; bash-invoked scripts are permitted to be non-executable.
for script in (
    "bin/2b-tt-agent.sh",
    "bin/2b-tt-ubuntu.sh",
    "bin/2b-tt-deb.sh",
    "bin/2b-tt-macos.sh",
    "bin/2e-tt-stage-mobile-agents.sh",
):
    assert (ROOT / script).stat().st_mode & 0o111, (
        f"{script} must be executable in Git; check chmod +x"
    )
ubuntu_builder = (ROOT / "bin" / "2b-tt-ubuntu.sh").read_text(encoding="utf-8")
assert 'bash "$ROOT/bin/2b-tt-deb.sh"' in ubuntu_builder, (
    "Invoke the Debian package builder via bash to avoid exit 126"
)

provisioner = (ROOT / "app" / "lib" / "ssh_provisioner.dart").read_text(encoding="utf-8")
deb_builder = (ROOT / "bin" / "2b-tt-deb.sh").read_text(encoding="utf-8")
assert 'dpkg --install' in provisioner, (
    "Install private-mode staged Ubuntu packages directly with dpkg"
)
assert 'apt-get install -y --no-install-recommends' not in provisioner, (
    "Never hand inaccessible private-mode staged packages to _apt"
)
assert "'Suggests: xdotool" in deb_builder
assert "'Depends: xdotool" not in deb_builder

assert "Verify Ubuntu packages with native dpkg" in workflow
assert 'sudo dpkg --install "dist/ubuntu/taptether-agent_' in workflow
assert "dpkg-deb --info" in workflow

assert "python3 bin/4-test-deb-packaging.py" in workflow, (
    "Run offline Debian payload regression test before expensive agent builds"
)
assert "run: bash bin/2b-tt-ubuntu.sh" in workflow
assert "run: bash bin/2b-tt-macos.sh" in workflow
assert "run: bash bin/2a-tt-ipa.sh --no-publish" in workflow
assert "run: bash bin/2a-tt-apk.sh --no-publish" in workflow
assert "run: bash bin/6-tt-publish-latest.sh" in workflow
assert "if: ${{ github.event_name == 'push' || inputs.task == 'release' }}" in workflow
assert "if: ${{ inputs.task == 'build' }}" in workflow
assert "TapTether-complete-build-" in workflow
assert "retention-days: 1" in workflow

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
assert "inputs.task == 'cleanup'" not in workflow
assert "needs.build-and-publish.result == 'success'" in workflow

# Regression guards: the Mac Finder installer must report and recover from
# launchd failures without copying raw pairing details or logs.
mac_setup = (ROOT / "bin" / "4-macos-agent-setup.sh").read_text(encoding="utf-8")
mac_tray = (ROOT / "desktop" / "macos" / "TapTetherTray.swift").read_text(
    encoding="utf-8")
assert "diagnostics) diagnostics" in mac_setup
assert "restart) start_agent" in mac_setup
assert "launchctl bootstrap" in mac_setup
assert "Privacy: no passwords, pairing tokens" in mac_setup
assert "Copy diagnostics" in mac_tray
assert "Open Accessibility settings" in mac_tray

# Guard against regressing the broken 0.6.7 remote class and F-key parser.
remote = (ROOT / "app" / "lib" / "main.dart").read_text(encoding="utf-8")
assert remote.count("Widget _connectedControls()") == 1
assert remote.count("Widget build(BuildContext context)") == 2
assert "if (RegExp(r'^f(?:[1-9]|1[0-2])$').hasMatch(id)) return id;" in remote
assert "}).hasMatch(id)) return id;" not in remote

# Presentation mode shares only authenticated LAN keyboard commands; no
# screen-reading or note capture is part of the 0.6.9 feature.
presentation = (ROOT / "app" / "lib" / "presentation_mode.dart").read_text(
    encoding="utf-8")
layout = (ROOT / "app" / "lib" / "remote_layout_settings.dart").read_text(
    encoding="utf-8")
assert 'Widget _landscapeRemote()' in remote
assert 'MediaQuery.orientationOf(context) == Orientation.landscape' in remote
assert 'Widget _presentationView(bool landscape)' in remote
assert 'SegmentedButton<bool>' in remote
assert 'PresentationShortcuts.start' in presentation
assert "static const next = 'Right';" in presentation
assert "static const previous = 'Left';" in presentation
assert "static const stop = 'Escape';" in presentation
assert "static const blankToggle = 'b';" in presentation
assert "this.presentationMode = false" in layout
assert "this.presentationApp = 'powerPoint'" in layout

print("PASS: one Actions workflow, auto Release on VERSION, three manual choices")
print("PASS: validate -> native agents -> IPA/APK -> publish, with same-run artifacts")
print("PASS: weekly cleanup and immutable version-tagged Latest releases")
