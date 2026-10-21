#!/usr/bin/env python3
"""Protect instant saved-device loading while allowing bounded UDP recovery.

No TCP sweep during heartbeats. After zero online, throttle a bounded\nagent-port-only TCP recovery across the current Wi-Fi CIDR.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
main = (root / 'app/lib/main.dart').read_text()
a = main.index('  Future<void> _refreshHeartbeats() async {')
b = main.index('  // Recover saved pairings quietly', a)
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
assert 'probeAgentControlPorts(' in recovery
assert 'parallelism: 24' in recovery
assert 'maxHits: 16' in recovery
assert 'Duration(minutes: 10)' in recovery
assert '_online.values.any((online) => online)' in recovery
assert '_reconcileScannedAgent(address, passive: true)' in recovery
assert 'if (_probingOfflineAgents)' not in recovery
assert 'checking: _checkingHeartbeat || _recoveringDiscovery' in main
assert "Checking TapTether agent addresses on this Wi-Fi" in main
assert '_lastPassiveDiscovery = null;' in main
print('PASS saved-only heartbeat, passive UDP plus throttled TCP recovery')
