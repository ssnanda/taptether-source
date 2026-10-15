import 'dart:async';

import 'package:flutter/material.dart';

import 'lan_scan.dart';
import 'computer_store.dart';

/// Injecting a scanner permits deterministic tests of authenticated
/// scan-to-paired-device reconciliation without touching real network hosts.
typedef LanRangeScanner = Future<List<LanHost>> Function(
  String prefix, {
  void Function(int completed, int total)? onProgress,
  void Function(LanHost candidate)? onAgentFound,
  bool Function()? cancelled,
});

/// Manual on-device /24 scan. No internet API, cloud account or analytics.
class LanScanScreen extends StatefulWidget {
  const LanScanScreen({
    super.key, this.initialIp, this.knownComputers = const [],
    this.macResolver,
    this.verifyPairedAgent,
    this.scanRange,
    this.initialNetwork,
  });
  final String? initialIp;
  final List<SavedComputer> knownComputers;
  final Future<Map<String, String>> Function()? macResolver;
  /// Triggered only on explicit user scan. The caller authenticates this IP
  /// with a saved TLS certificate pin AND paired-phone credentials before
  /// returning the matching computer name or changing a saved record.
  final Future<String?> Function(String ip)? verifyPairedAgent;
  final LanRangeScanner? scanRange;
  final DetectedLanRange? initialNetwork;

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
  Map<String, String> _cachedMacs = {};
  final Map<String, String> _verifiedAgents = {};
  final Set<String> _startedVerification = {};
  final List<Future<void>> _pendingVerifications = [];
  bool _busy = false;
  bool _cancel = false;
  int _completed = 0;
  int _total = 254;
  bool _scanWholeNetwork = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDefault());
  }

  Future<void> _loadDefault() async {
    final range = widget.initialNetwork ?? await detectLanRange();
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

  void _verifyCandidate(LanHost candidate) {
    if (_cancel || !mounted || widget.verifyPairedAgent == null) return;
    if (!candidate.openPorts.contains(48321) && !candidate.agentAnnounced) {
      return;
    }
    if (!_startedVerification.add(candidate.ip)) return;
    final task = _authenticateCandidate(candidate.ip);
    _pendingVerifications.add(task);
  }

  Future<void> _authenticateCandidate(String ip) async {
    try {
      final name = await widget.verifyPairedAgent!(ip);
      if (mounted && !_cancel && name != null) {
        setState(() => _verifiedAgents[ip] = name);
      }
    } catch (_) {
      // A foreign service or an unpaired agent must never interrupt IP Scan.
    }
  }

  void _showAgentCandidate(LanHost host) {
    _verifyCandidate(host);
    if (!mounted || _cancel || _hosts.any((item) => item.ip == host.ip)) {
      return;
    }
    // A listening TapTether port can appear while other IPs are still being
    // scanned. Show the candidate immediately while verification runs.
    setState(() {
      _hosts = [..._hosts, host]..sort((a, b) {
        final left = a.ip.split('.').map(int.parse).toList();
        final right = b.ip.split('.').map(int.parse).toList();
        for (var i = 0; i < 4; i++) {
          final diff = left[i].compareTo(right[i]);
          if (diff != 0) return diff;
        }
        return 0;
      });
    });
  }

  Future<void> _startScan() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final prefix = _prefix.text.trim();
    if (!validPrivate24Prefix(prefix)) {
      setState(() => _error = 'Enter a private IPv4 /24 prefix (e.g. 192.168.1).');
      return;
    }
    // Whole-network mode follows the detected Wi-Fi CIDR (e.g. both
    // 192.168.20 and 192.168.21 for a /23). Only an explicit custom /24
    // prefix overrides that network-wide choice.
    final targets = _scanWholeNetwork && _network != null &&
            !_editedPrefix && _network!.scanPrefixes.length <= 8
        ? _network!.scanPrefixes
        : [prefix];
    setState(() {
      _error = null;
      _hosts = [];
      _cachedMacs = {};
      _verifiedAgents.clear();
      _startedVerification.clear();
      _pendingVerifications.clear();
      _completed = 0;
      _total = targets.length * 254;
      _cancel = false;
      _busy = true;
    });
    try {
      final found = <String, LanHost>{};
      for (var index = 0; index < targets.length && !_cancel; index++) {
        final scannedBefore = index * 254;
        final group = await (widget.scanRange ?? scanPrivate24)(targets[index],
          cancelled: () => _cancel,
          onAgentFound: _showAgentCandidate,
          onProgress: (done, _) {
            if (mounted) {
              setState(() => _completed = scannedBefore + done);
            }
          },
        );
        for (final computer in group) {
          found[computer.ip] = computer;
          _verifyCandidate(computer);
        }
        if (mounted) {
          setState(() {
            _hosts = found.values.toList()..sort((a, b) {
              final aa = a.ip.split('.').map(int.parse).toList();
              final bb = b.ip.split('.').map(int.parse).toList();
              for (var i = 0; i < 4; i++) {
                final diff = aa[i].compareTo(bb[i]);
                if (diff != 0) return diff;
              }
              return 0;
            });
          });
        }
      }
      // Do not declare the scan finished while identity checks are in
      // flight. Results are saved as soon as each individual match succeeds.
      if (!_cancel) {
        await Future.wait(_pendingVerifications);
      }
      // A paired, authenticated desktop can read its own ARP cache;
      // mobile iOS cannot directly inspect other devices' MAC addresses.
      if (!_cancel && widget.macResolver != null) {
        final neighbors = await widget.macResolver!();
        if (mounted) setState(() => _cachedMacs = neighbors);
      }
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
      _verifyCandidate(found ??
          LanHost(ip: ip, hostname: ip, openPorts: const []));
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

  String _subtitle(LanHost device) {
    final matches = widget.knownComputers.where((e) =>
        e.host == device.ip && e.macAddress.isNotEmpty);
    final mac = device.macAddress ?? _cachedMacs[device.ip] ??
        (matches.isNotEmpty ? matches.first.macAddress : null);
    final verified = _verifiedAgents[device.ip];
    return '${verified == null ? device.scanSubtitle : 'Paired: $verified · Verified agent'}'
        '${mac == null || mac.isEmpty ? '' : '\nMAC: $mac'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan local network')),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Discover nearby devices on your local Wi-Fi.'),
          const SizedBox(height: 12),
          if (_network != null) ...[
            Text('Phone Wi-Fi: ${_network!.ip} · Network: ${_network!.cidr}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (_network!.scanPrefixes.length > 1 &&
                _network!.scanPrefixes.length <= 8)
              SwitchListTile.adaptive(
                key: const ValueKey('scan-whole-network'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Scan entire Wi-Fi network'),
                subtitle: Text('${_network!.cidr} · '
                    '${_network!.scanPrefixes.length} ranges'),
                value: _scanWholeNetwork,
                onChanged: _busy ? null :
                    (value) => setState(() => _scanWholeNetwork = value),
              ),
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
              helperText: 'Detects the Wi-Fi subnet; you can also choose a /24 range.',
            ),
          ),
          const SizedBox(height: 12),
          if (_busy) ...[
            LinearProgressIndicator(value: _completed / _total),
            const SizedBox(height: 10),
            Text('Checking $_completed of $_total addresses…'),
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
          if (_verifiedAgents.isNotEmpty) ...[
            Text(
              '${_verifiedAgents.length} existing paired computer(s) verified',
              key: const ValueKey('scan-verified-pairs'),
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 8),
          ],
          Text('Devices found: ${_hosts.length}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!_busy && _hosts.isEmpty && _error == null)
            const Text('No devices detected yet. Some networks block discovery '
                'and devices with closed ports may not appear.'),
          for (final device in _hosts)
            Card(child: ListTile(
              leading: Icon(device.platform == 'darwin'
                  ? Icons.laptop_mac
                  : device.agentAnnounced || device.openPorts.contains(48321)
                      ? Icons.desktop_windows_outlined
                      : Icons.devices_other_outlined),
              title: Text(_verifiedAgents[device.ip] ?? device.displayName),
              subtitle: Text(_subtitle(device)),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, device.ip),
            )),
          const SizedBox(height: 16),
          Text('MAC addresses come from paired agents or their LAN '
              'neighbor caches when available. They may be missing '
              'or stale, and do not prove a device is online.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          const Text('Tap any result to use its IP in the computer pairing form. '
              'An IP scan does not authorize access to a computer.'),
        ],
      )),
    );
  }
}
