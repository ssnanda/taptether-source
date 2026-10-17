#!/usr/bin/env python3
"""Protect My Devices from accidental automatic LAN-wide scanning.

Quick manual Discover/Scan IPs are intentionally outside this method.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
main = (root / 'app/lib/main.dart').read_text()
a = main.index('  Future<void> _refreshHeartbeats() async {')
b = main.index('  Future<void> _labelCurrentNetwork()', a)
body = main[a:b]
for forbidden in ('findNearbyDevices(', 'probeAgentControlPorts(',
                  'scanPrefixes', 'InternetAddress.lookup(',
                  'recoveryCandidates(', 'agentTcpProbeAddresses('):
    assert forbidden not in body, (
        f'My Devices heartbeat must not start discovery: {forbidden}'
    )
assert "_pingSavedDevice(device, phone)" in body
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
print('PASS saved-only dashboard heartbeat, collapsed discovery, back navigation, fast local auth')
