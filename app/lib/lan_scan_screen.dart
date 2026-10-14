import 'dart:async';

import 'package:flutter/material.dart';

import 'lan_scan.dart';

/// Manual on-device /24 scan. No internet API, cloud account or analytics.
class LanScanScreen extends StatefulWidget {
  const LanScanScreen({super.key, this.initialIp});
  final String? initialIp;

  @override
  State<LanScanScreen> createState() => _LanScanScreenState();
}

class _LanScanScreenState extends State<LanScanScreen> {
  final _prefix = TextEditingController();
  final _specificIp = TextEditingController();
  DetectedLanRange? _network;
  bool _checkingSpecificIp = false;
  String? _notRespondingIp;
  bool _editedPrefix = false;
  List<LanHost> _hosts = [];
  bool _busy = false;
  bool _cancel = false;
  int _completed = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDefault());
  }

  Future<void> _loadDefault() async {
    final range = await detectLanRange();
    if (!mounted) return;
    setState(() {
      _network = range;
      if (!_editedPrefix) {
        _prefix.text = range?.activePrefix ??
            (prefixFromIp(widget.initialIp ?? '') ?? '');
      }
      if (_specificIp.text.isEmpty &&
          widget.initialIp != null && widget.initialIp!.isNotEmpty) {
        _specificIp.text = widget.initialIp!;
      }
    });
  }

  @override
  void dispose() {
    _cancel = true;
    _prefix.dispose();
    _specificIp.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final prefix = _prefix.text.trim();
    if (!validPrivate24Prefix(prefix)) {
      setState(() => _error = 'Enter a private IPv4 /24 prefix (e.g. 192.168.1).');
      return;
    }
    setState(() {
      _error = null;
      _hosts = [];
      _completed = 0;
      _cancel = false;
      _busy = true;
    });
    try {
      final found = await scanPrivate24(prefix,
        cancelled: () => _cancel,
        onProgress: (done, _) {
          if (mounted) setState(() => _completed = done);
        },
      );
      if (mounted) setState(() => _hosts = found);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'The scan could not finish. Check Wi-Fi or local-network permission.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkSpecificIp() async {
    if (_checkingSpecificIp || _busy) return;
    final ip = _specificIp.text.trim();
    if (!validPrivate24Prefix(prefixFromIp(ip) ?? '')) {
      setState(() => _error = 'Enter a private IPv4 address, e.g. 192.168.1.77');
      return;
    }
    setState(() {
      _checkingSpecificIp = true;
      _notRespondingIp = null;
      _error = null;
    });
    try {
      final found = await checkPrivateLanIp(ip);
      if (!mounted) return;
      setState(() {
        if (found == null) {
          _notRespondingIp = ip;
        } else {
          _hosts = [
            for (final item in _hosts)
              if (item.ip != found.ip) item,
            found,
          ]..sort((a, b) {
            final left = a.ip.split('.').map(int.parse).toList();
            final right = b.ip.split('.').map(int.parse).toList();
            for (var i = 0; i < 4; i++) {
              final diff = left[i].compareTo(right[i]);
              if (diff != 0) return diff;
            }
            return 0;
          });
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to check that LAN IP. '
            'Verify Wi-Fi and local-network permissions.');
      }
    } finally {
      if (mounted) setState(() => _checkingSpecificIp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan local network')),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Scan one local /24 subnet for common TCP services. '
              'This runs on your phone and never uploads network information.'),
          const SizedBox(height: 12),
          if (_network != null) ...[
            Text('Phone Wi-Fi: ${_network!.ip} · Network: ${_network!.cidr}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (_network!.scanPrefixes.length > 1)
              DropdownButtonFormField<String>(
                key: const ValueKey('lan-range-picker'),
                initialValue: _network!.scanPrefixes.contains(_prefix.text)
                    ? _prefix.text : _network!.activePrefix,
                decoration: const InputDecoration(
                  labelText: 'Choose nearby /24 scan range',
                  isDense: true,
                ),
                items: [
                  for (final value in _network!.scanPrefixes)
                    DropdownMenuItem(value: value, child: Text('$value.0/24')),
                ],
                onChanged: _busy ? null : (selected) {
                  if (selected != null) {
                    setState(() {
                      _editedPrefix = true;
                      _prefix.text = selected;
                    });
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _prefix,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            onChanged: (_) => _editedPrefix = true,
            decoration: const InputDecoration(
              labelText: 'Network prefix',
              hintText: '192.168.1',
              helperText: 'Checks .1–.254 for the selected /24. Larger subnets offer more ranges above.',
            ),
          ),
          const SizedBox(height: 12),
          if (_busy) ...[
            LinearProgressIndicator(value: _completed / 254),
            const SizedBox(height: 10),
            Text('Checking $_completed of 254 addresses…'),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: () => _cancel = true,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop scan')),
          ] else
            FilledButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.radar),
              label: const Text('Start IP scan'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(
                color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 18),
          Text('Check a specific computer',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('A Mac may not appear in a full scan if its services are '
              'blocked. Check its known IP directly, or pair it manually.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(
              key: const ValueKey('check-specific-ip'),
              controller: _specificIp,
              enabled: !_busy && !_checkingSpecificIp,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Computer IP',
                hintText: '192.168.1.77',
              ),
            )),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _busy || _checkingSpecificIp
                  ? null : _checkSpecificIp,
              child: Text(_checkingSpecificIp ? 'Checking…' : 'Check IP'),
            ),
          ]),
          if (_notRespondingIp != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No tested services responded at $_notRespondingIp. '
                      'The computer may still be online with its ports '
                      'closed. This is not proof that it is offline.'),
                  TextButton(
                    onPressed: () => Navigator.pop(context, _notRespondingIp),
                    child: const Text('Use this IP for pairing anyway'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Text('Devices found: ${_hosts.length}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!_busy && _hosts.isEmpty && _error == null)
            const Text('Results appear after the scan. Devices with all '
                'scanned ports closed may not appear.'),
          for (final device in _hosts)
            Card(child: ListTile(
              leading: Icon(device.platform == 'darwin'
                  ? Icons.laptop_mac
                  : device.agentAnnounced || device.openPorts.contains(48321)
                      ? Icons.desktop_windows_outlined
                      : Icons.devices_other_outlined),
              title: Text(device.displayName),
              subtitle: Text(device.scanSubtitle),
              isThreeLine: device.openPorts.isNotEmpty,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, device.ip),
            )),
          const SizedBox(height: 16),
          Text('iOS does not expose a reliable list of other devices’ '
              'MAC addresses to TapTether. Device types are best-effort '
              'from observed services or unverified agent announcements. '
              'Pairing still requires authentication.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          const Text('Tap any result to use its IP in the computer pairing form. '
              'An IP scan does not authorize access to a computer.'),
        ],
      )),
    );
  }
}
