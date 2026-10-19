#!/usr/bin/env python3
"""Protect instant saved-device loading while allowing bounded UDP recovery.

No automatic TCP subnet scanning or unicast sweeps. Manual discovery is separate.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
main = (root / 'app/lib/main.dart').read_text()
a = main.index('  Future<void> _refreshHeartbeats() async {')
b = main.index('  // Passive zero-online recovery.', a)
body = main[a:b]
for forbidden in ('findNearbyDevices(', 'probeAgentControlPorts(',
                  'scanPrefixes', 'InternetAddress.lookup(',
                  'recoveryCandidates(', 'agentTcpProbeAddresses('):
    assert forbidden not in body, (
        f'My Devices heartbeat must not start discovery: {forbidden}'
    )
assert "unawaited(_recoverSavedDevices())" in body
assert "_probeSavedDevice(device, phone)" in body
assert "savedComputers.toList()" in body
assert "Future.wait(savedSnapshot.map(" in body
assert "bool _showOffline = true;" in main
assert "String _locationFilter = 'all';" in main
assert "bool _showQuickActions = false;" in main
assert "Icons.arrow_back" in main
assert "'Back to My Devices'" in main
assert "tooltip: 'Switch computer'" not in main
assert "if (_showQuickActions) ...[" in main
assert "if (searching || !_discoveryReport.isEmpty)" in main
assert "final phone = await _phoneIdentity();" in main
assert "currentAgent = await agent.agentVersion();" in main
recovery = main.split('  Future<void> _recoverSavedDevices(', 1)[1].split(
    '  Future<void> _labelCurrentNetwork()', 1)[0]
assert 'broadcastOnly: true' in recovery
assert 'scanPrivate24(' not in recovery
assert 'probeAgentControlPorts(' not in recovery
print('PASS saved-only heartbeat, passive bounded UDP recovery, no TCP sweep')
