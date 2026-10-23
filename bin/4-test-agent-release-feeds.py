#!/usr/bin/env python3
"""Offline regressions for independent agent releases and sync version policy."""
import importlib.util
import contextlib
import io
import json
import sys
import urllib.error
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "bin" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

ubuntu = load("ubuntu_release_info", "7b-tt-ubuntu-release-info.py")
guard = load("full_sync_guard", "4-guard-release-sync.py")
def release(tag, version):
    arch = 'amd64'
    return {
        'tag_name': tag, 'name': f'TapTether Ubuntu {version}' if tag == 'ubuntu-current'
        else f'TapTether {version} (rolling downloads)',
        'assets': [{
            'name': f'TapTetherAgent-Ubuntu-{arch}.deb',
            'digest': 'sha256:' + 'a'*64,
            'browser_download_url':
                f'https://github.com/ssnanda/taptether.com/releases/download/{tag}/TapTetherAgent-Ubuntu-{arch}.deb'
        }]
    }

full = release('current', '0.7.7+67')
partial = release('ubuntu-current', '0.7.8+68')
v, newer, digest, url = ubuntu.select_release(
    {'current': full, 'ubuntu-current': partial}, 'amd64', '0.7.7+67')
assert (v, newer, digest) == ('0.7.8+68', 'yes', 'a'*64)
assert '/ubuntu-current/' in url
v, newer, *_ = ubuntu.select_release(
    {'current': full, 'ubuntu-current': partial}, 'amd64', '0.8.0+100')
assert (v, newer) == ('0.7.8+68', 'no')
assert ubuntu.select_release({'current': full}, 'amd64', '0.7.5+65')[0] == '0.7.7+67'
malformed = release('ubuntu-current', '0.7.8+68')
malformed['assets'][0]['digest'] = 'sha256:invalid'
try:
    ubuntu.select_release({'current': full, 'ubuntu-current': malformed}, 'amd64', '0.7.7+67')
    raise AssertionError('Invalid rolling asset must reject the selection')
except ValueError:
    pass
guard.check_sync('0.8.0+100', {'ubuntu-current': '0.7.8+68',
                              'macos-current': '0.7.9+69',
                              'windows-current': '0.7.7+67'})
for v in ['0.7.8+68', '0.7.7+67']:
    try:
        guard.check_sync(v, {'ubuntu-current': '0.7.8+68'})
        raise AssertionError('Full release would downgrade Ubuntu')
    except ValueError:
        pass

publisher = (ROOT/'bin'/'6-tt-publish-agent-only.sh').read_text()
workflow = (ROOT/'.github'/'workflows'/'taptether.yml').read_text()
mobile = (ROOT/'app'/'lib'/'main.dart').read_text()
mac = (ROOT/'bin'/'8-tt-update-macos.sh').read_text()
windows = (ROOT/'desktop'/'windows'/'Update-TapTether.ps1').read_text()
system = (ROOT/'bin'/'9-tt-system-update-ubuntu.sh').read_text()
assert 'rolling="$platform-current"' in publisher
assert 'gh release create "$rolling"' in publisher
assert 'tag="agent-$platform-v$version"' not in publisher
assert '--target main' in publisher
assert 'TapTether.ipa' not in publisher and 'TapTether.apk' not in publisher
assert 'bin/4-guard-release-sync.py' in workflow
assert 'bin/6-tt-publish-agent-only.sh ubuntu' in workflow
assert 'bin/6-tt-publish-agent-only.sh macos' in workflow
assert 'bin/6-tt-publish-agent-only.sh windows' in workflow
assert 'macos-current' in mac and 'windows-current' in windows and '7b-tt-ubuntu-release-info.py' in system
# Ensure legacy macOS updaters are bootstrapped using "current", while new
# updaters continue when only "macos-current" is published.
assert 'gh release create current' in publisher
assert 'gh release upload current' in publisher
assert 'current_title' in publisher and '(macOS bootstrap)' in publisher
assert 'gh api --method DELETE "repos/$repo/releases/assets/$id"' not in publisher
assert 'for tag in ("current", "macos-current"):' in mac
assert 'if exc.code == 404:' in mac
embedded = mac.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
expected_url = ('https://github.com/ssnanda/taptether.com/releases/download/'
                'macos-current/TapTetherAgent-macOS-arm64.tar.gz')
def mac_response(tag, version):
    return {
        'tag_name': tag, 'name': f'TapTether macOS {version} (agent-only rolling downloads)',
        'assets': [{
            'name': 'TapTetherAgent-macOS-arm64.tar.gz',
            'digest': 'sha256:' + 'a'*64,
            'browser_download_url': (
                'https://github.com/ssnanda/taptether.com/releases/download/'
                f'{tag}/TapTetherAgent-macOS-arm64.tar.gz'),
        }],
    }
class FakeAPIResponse:
    def __init__(self, value):
        self.value = value
    def __enter__(self):
        return self
    def __exit__(self, *args):
        return False
    def read(self):
        return json.dumps(self.value).encode()
def simulate_missing_current(req, timeout):
    tag = req.full_url.rsplit('/', 1)[-1]
    if tag == 'current':
        raise urllib.error.HTTPError(req.full_url, 404, "Not Found", {}, None)
    assert tag == 'macos-current'
    return FakeAPIResponse(mac_response(tag, '0.8.9+125'))
result = io.StringIO()
with patch.object(sys, 'argv', ['release-feed', 'arm64', '0.8.9+124']), \
        patch('urllib.request.urlopen', side_effect=simulate_missing_current), \
        contextlib.redirect_stdout(result):
    exec(compile(embedded, 'mac-updater-release-selector', 'exec'), {})
assert result.getvalue().strip() == (
    '0.8.9+125\tyes\t' + 'a'*64 + '\t' + expected_url)

assert 'ubuntu-current' in mobile and 'windows-current' in mobile and 'macos-current' in mobile
print('PASS independent Ubuntu/macOS/Windows release selection, mobile awareness and full sync guard')
