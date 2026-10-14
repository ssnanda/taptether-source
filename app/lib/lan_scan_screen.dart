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
  DetectedLanRange? _network;
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
    });
  }

  @override
  void dispose() {
    _cancel = true;
    _prefix.dispose();
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
          const SizedBox(height: 20),
          Text('Devices found: ${_hosts.length}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!_busy && _hosts.isEmpty && _error == null)
            const Text('Results appear after the scan. Devices with all '
                'scanned ports closed may not appear.'),
          for (final device in _hosts)
            Card(child: ListTile(
              leading: Icon(device.openPorts.contains(48321)
                  ? Icons.desktop_windows_outlined
                  : Icons.devices_other_outlined),
              title: Text(device.hostname),
              subtitle: Text('${device.ip} · ${device.deviceHint}\n'
                  'Open TCP: ${device.openPorts.join(", ")}'),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, device.ip),
            )),
          const SizedBox(height: 16),
          Text('MAC addresses are generally unavailable to iPhone and '
              'Android apps. Hostnames and device types are best-effort '
              'hints, not verified identities.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          const Text('Tap any result to use its IP in the computer pairing form. '
              'An IP scan does not authorize access to a computer.'),
        ],
      )),
    );
  }
}
