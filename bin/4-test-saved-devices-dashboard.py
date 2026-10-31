#!/usr/bin/env python3
"""Protect instant saved-device loading while allowing bounded UDP recovery.

No TCP sweep during heartbeats. When a paired computer is offline, throttle bounded agent-port-only TCP\nrecovery across the current Wi-Fi CIDR.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
main = (root / 'app/lib/main.dart').read_text()
a = main.index('  Future<void> _refreshHeartbeats() async {')
b = main.index('  // Recover each offline saved pairing quietly', a)
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
assert "bool _showAllDevices = false;" in main  # Local scope is the default
assert "allSavedComputers(savedComputers" in main
assert "savedDeviceOnNetwork(_wifiRange, device.host)" in main
assert "bool _showQuickActions = false;" in main
assert "Icons.arrow_back" in main
assert "'Back to My Devices'" in main
assert "tooltip: 'Switch computer'" not in main
assert "if (_wifiRange != null && _showQuickActions) ...[" in main
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
assert 'savedComputers.every((d) => _online[d.id] == true)' in recovery
assert '_reconcileScannedAgent(address, passive: true)' in recovery
assert 'if (_probingOfflineAgents)' not in recovery
assert "locationFilter: 'all'" in main
assert "'On This Network'" in (root / 'app/lib/device_dashboard_header.dart').read_text()
assert "'All Devices'" in (root / 'app/lib/device_dashboard_header.dart').read_text()
# Dashboard statuses use compact semantic icons, not flashing prose.
assert "Checking TapTether agent addresses on this Wi-Fi" not in main
assert "Tooltip(" in main
assert "Icons.travel_explore" in main
assert "Icons.check_circle" in main
assert "Icons.radio_button_unchecked" in main
header = (root / 'app/lib/device_dashboard_header.dart').read_text()
assert "key: const ValueKey('locate-saved-devices')" in header
assert "key: const ValueKey('refresh-device-status')" not in main
assert "_refreshDevicesManually" in main
assert "DeviceLocationLog.instance.record" in main
assert '_lastPassiveDiscovery = null;' in main
# Backups are accessible from the main drawer, not nested under Appearance.
security = (root / 'app/lib/security_settings_screen.dart').read_text()
drawer = main.split('  Widget appDrawer()', 1)[1].split(
    '  Widget _offlineHome()', 1)[0]
assert "key: const ValueKey('drawer-device-backups')" in drawer
assert "openDeviceBackups();" in drawer
assert "Text('Device backup')" not in security
assert "DeviceBackupScreen(" in main

# All mutable saved-device stores request encrypted backup only after writes.
backup = (root / 'app/lib/automatic_device_backup.dart').read_text()
assert 'void requestSoon()' in backup
assert '_changesWhileBusy' in backup
assert 'DeviceBackupCodec.encrypt(' in backup
for filename in (
    'computer_store.dart', 'lg_webos_client.dart', 'samsung_tv_client.dart',
    'xbox_smartglass.dart', 'phone_ssh_keys.dart', 'lg_thinq_api.dart',
    'network_location.dart', 'ssh_host_trust.dart',
):
    contents = (root / 'app/lib' / filename).read_text()
    assert 'AutomaticDeviceBackup.instance.requestSoon();' in contents, filename
backup_screen = (root / 'app/lib/device_backup_screen.dart').read_text()
assert 'Back up automatically on changes' in backup_screen
assert "Encrypt backups (optional)" in backup_screen
assert "backup-password-input" in backup_screen
assert "save-backup-password" in backup_screen
assert "Future<void> _savePassword()" in backup_screen
assert "_password(confirm: true)" not in backup_screen
assert "final entered = await _password(" not in backup_screen
assert "Future<String?> _requestImportPassword()" in backup_screen
print('PASS saved-only heartbeat, local default, and automatic backup hooks')
