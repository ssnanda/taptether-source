#!/usr/bin/env python3
"""Require an explicit version bump and human-facing note for protected macOS cores."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
NOTES = "docs/architecture/core-compatibility-and-release-notes.md"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def at(ref, path):
    try:
        return git("show", f"{ref}:{path}")
    except subprocess.CalledProcessError:
        return ""


def check(base):
    changed = set(git("diff", "--name-only", base, "HEAD").splitlines())
    if not changed:
        return
    rules = [
        ("Input Core", "INPUT_CORE_VERSION",
         ("agent/cmd/taptether-input-core/", "agent/internal/inputcore/")),
        ("Screen Core", "SCREEN_CORE_VERSION",
         ("agent/cmd/taptether-screen-core/", "agent/internal/screencap/")),
    ]
    notes = (ROOT / NOTES).read_text()
    failures = []
    for label, version_file, folders in rules:
        executable_changes = [
            p for p in changed if p.startswith(folders)
            and not p.endswith("_test.go")
        ]
        if not executable_changes:
            continue
        old_version = at(base, version_file)
        version_path = ROOT / version_file
        new_version = version_path.read_text().strip() if version_path.exists() else ""
        if not new_version or new_version == old_version:
            failures.append(
                f"{label} source modified without incrementing {version_file}: "
                + ", ".join(executable_changes)
            )
        if NOTES not in changed or f"{label} {new_version}" not in notes:
            failures.append(
                f"{label} source modified: update {NOTES} with "
                f"'{label} {new_version}' and explain consent impact"
            )
    if failures:
        raise SystemExit("Protected macOS core release check failed:\n- "
                         + "\n- ".join(failures))
    print("PASS: protected macOS cores are unchanged or explicitly versioned")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: 4-guard-macos-cores.py <base-commit>")
    check(sys.argv[1])
