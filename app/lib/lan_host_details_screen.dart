import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'deep_port_scan.dart';
import 'lan_scan.dart';
import 'lg_appliance_discovery.dart';
import 'lg_webos_client.dart';
import 'samsung_tv_client.dart';
import 'scan_report.dart';

/// Level two of the local network scanner.
/// Opening this screen never connects to a service. Checks require a tap,
/// and diagnostics are kept only on device until explicitly copied.
class LanHostDetailsScreen extends StatefulWidget {
  const LanHostDetailsScreen({
    super.key,
    required this.device,
    required this.network,
    this.verifiedName,
    this.macAddress,
    this.checkLg = false,
    this.checkSamsung = false,
  });

  final LanHost device;
  final DetectedLanRange network;
  final String? verifiedName;
  final String? macAddress;
  final bool checkLg;
  final bool checkSamsung;

  @override
  State<LanHostDetailsScreen> createState() => _LanHostDetailsScreenState();
}

class _LanHostDetailsScreenState extends State<LanHostDetailsScreen> {
  final ScanReport _report = ScanReport();
  final Map<int, TcpProbeStatus> _portStatus = {};
  bool _quick = true;
  bool _lg = false;
  bool _samsung = false;
  bool _deep = false;
  bool _running = false;
  bool _cancel = false;
  int _checked = 0;
  int _total = 0;
  String? _error;
  String? _vendorInfo;
  final List<int> _deepOpen = [];

  @override
  void initState() {
    super.initState();
    _lg = widget.checkLg;
    _samsung = widget.checkSamsung;
    _report.add('Selected IP: ${widget.device.ip}');
    _report.add('Network: ${widget.network.cidr}');
    _report.add('Name hint: ${widget.verifiedName ?? widget.device.displayName}');
    _report.add('Initially observed TCP: '
        '${widget.device.openPorts.isEmpty ? "none" : widget.device.openPorts.join(", ")}');
    final mac = widget.macAddress;
    if (mac != null && mac.isNotEmpty) {
      _report.add('Saved or neighbor MAC hint: $mac (not authenticated)');
    }
    _report.add('Device name, IP, MAC and open ports are hints, '
        'not proof of manufacturer, model or online state.');
  }

  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _report.output));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device diagnostics copied')));
    }
  }

  Future<void> _scan() async {
    if (_running || !(_quick || _lg || _samsung || _deep)) {
      return;
    }
    final ip = widget.device.ip;
    setState(() {
      _running = true;
      _cancel = false;
      _checked = 0;
      _total = 0;
      _error = null;
      _vendorInfo = null;
      _deepOpen.clear();
      _portStatus.clear();
    });
    try {
      // Refuse to scan a remembered home address when now on another Wi-Fi.
      final current = await detectLanRange();
      if (current == null || !lanRangeContains(current, ip) ||
          !lanRangeContains(widget.network, ip)) {
        throw StateError('Join the Wi-Fi network of this IP to scan it.');
      }
      _report.add('Targeted scan started for $ip. '
          'Quick: $_quick; LG: $_lg; Samsung: $_samsung; Deep TCP: $_deep');
      if (_quick && !_cancel) {
        for (final port in lanScanPorts) {
          if (_cancel) {
            break;
          }
          final result = await probeTcpPort(ip, port,
              timeout: const Duration(milliseconds: 500));
          _portStatus[port] = result;
        }
        _report.add('$ip: common TCP ports open: '
            '${_portStatus.entries.where((e) =>
                e.value == TcpProbeStatus.open).map((e) =>
                e.key).join(", ")}'
            ' (blank means none responded, not offline)');
      }
      if (_lg && !_cancel) {
        final results = await Future.wait([
          probeTcpPort(ip, 3000,
              timeout: const Duration(milliseconds: 600)),
          probeTcpPort(ip, 3001,
              timeout: const Duration(milliseconds: 600)),
        ]);
        _portStatus[3000] = results[0];
        _portStatus[3001] = results[1];
        final available = results.contains(TcpProbeStatus.open);
        final hello = available ? await readLgWebOsHello(ip,
            connectTimeout: const Duration(milliseconds: 600),
            replyTimeout: const Duration(seconds: 2)) : null;
        final protocol = hello != null
            ? 'LG webOS hello confirmed'
            : available ? 'LG control port open; identity unverified'
            : 'No LG webOS control response (not proof of offline)';
        _vendorInfo = protocol;
        _report.add('$ip: $protocol');
        if (!_cancel) {
          final clues = await LgApplianceLanDiscovery().scan(current);
          final matches = clues.where((entry) => entry.ip == ip);
          for (final item in matches) {
            _report.add('$ip: LG SSDP hint: ${item.name}, '
                'model ${item.model.isEmpty ? "not advertised" : item.model}, '
                'server ${item.server}');
          }
          if (matches.isEmpty) {
            _report.add('$ip: no LG SSDP announcement; this is common '
                'for cloud-managed appliances');
          }
        }
      }
      if (_samsung && !_cancel) {
        final candidate = await probeSamsungTv(ip);
        final result = candidate == null
            ? 'No confirmed Samsung Tizen metadata'
            : 'Samsung Tizen detected; model '
                '${candidate.model.isEmpty ? "not reported" : candidate.model}';
        _report.add('$ip: $result');
        _vendorInfo = result;
      }
      if (_deep && !_cancel) {
        _report.add('$ip: probing TCP ports 1–65535 with bounded '
            'concurrency. No application commands.');
        await scanDeepTcp(
          hosts: [ip],
          network: current,
          cancelled: () => _cancel || !mounted,
          onProgress: (done, total, _) {
            if (mounted && (done % 256 == 0 || done == total)) {
              setState(() { _checked = done; _total = total; });
            }
          },
          onHostCompleted: (result) {
            _deepOpen.addAll(result.openPorts);
            _report.add('$ip: checked ${result.checked} TCP ports; '
                'open: ${result.openPorts.isEmpty
                    ? "none identified" : result.openPorts.join(", ")}');
          },
        );
      }
      _report.add(_cancel
          ? '$ip: targeted scan cancelled'
          : '$ip: selected targeted checks completed');
    } catch (error) {
      _report.add('$ip: targeted scan did not complete');
      if (mounted) {
        setState(() => _error = error is StateError
            ? error.message : 'Could not finish local diagnostics.');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mac = widget.macAddress;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device diagnostics'),
        actions: [
          IconButton(
            key: const ValueKey('copy-host-report'),
            tooltip: 'Copy device diagnostics',
            onPressed: _copyReport,
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.verifiedName ?? widget.device.displayName,
              style: Theme.of(context).textTheme.titleLarge),
          SelectableText(widget.device.ip,
              style: Theme.of(context).textTheme.titleMedium),
          if (mac != null && mac.isNotEmpty)
            SelectableText('MAC hint: $mac'),
          Text('Initially observed: ${widget.device.openPorts.isEmpty
              ? "no common TCP responses"
              : "TCP ${widget.device.openPorts.join(", ")}"}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          const Text('Select checks for this IP. These do not pair with '
              'or control the device. A closed port does not mean offline.'),
          const Divider(height: 28),
          CheckboxListTile(
            key: const ValueKey('host-quick-checkbox'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Common TCP ports'),
            value: _quick,
            onChanged: _running ? null : (value) =>
                setState(() => _quick = value ?? false),
          ),
          CheckboxListTile(
            key: const ValueKey('host-lg-checkbox'),
            contentPadding: EdgeInsets.zero,
            title: const Text('LG'),
            subtitle: const Text('webOS hello + SSDP appliance hint'),
            value: _lg,
            onChanged: _running ? null : (value) =>
                setState(() => _lg = value ?? false),
          ),
          CheckboxListTile(
            key: const ValueKey('host-samsung-checkbox'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Samsung'),
            subtitle: const Text('Read-only Tizen device metadata'),
            value: _samsung,
            onChanged: _running ? null : (value) =>
                setState(() => _samsung = value ?? false),
          ),
          CheckboxListTile(
            key: const ValueKey('host-deep-checkbox'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Deep TCP ports 1–65535'),
            subtitle: const Text('Slower; limited connections; stop anytime'),
            value: _deep,
            onChanged: _running ? null : (value) =>
                setState(() => _deep = value ?? false),
          ),
          const SizedBox(height: 10),
          if (_running) ...[
            LinearProgressIndicator(
              value: _total > 0 ? _checked / _total : null),
            const SizedBox(height: 6),
            Text(_total == 0 ? 'Checking this IP…'
                : 'Checked $_checked of $_total TCP ports'),
            OutlinedButton.icon(
              onPressed: () => setState(() => _cancel = true),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop diagnostics'),
            ),
          ] else
            FilledButton.icon(
              key: const ValueKey('run-host-checks'),
              onPressed: (_quick || _lg || _samsung || _deep)
                  ? _scan : null,
              icon: const Icon(Icons.radar),
              label: const Text('Scan this IP'),
            ),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: TextStyle(
                color: Theme.of(context).colorScheme.error)),
          ),
          if (_portStatus.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('TCP results', style: Theme.of(context).textTheme.titleMedium),
            for (final port in _portStatus.keys.toList()..sort())
              Text('Port $port: ${tcpProbeLabel(_portStatus[port]!)}'),
          ],
          if (_vendorInfo != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_vendorInfo!)),
          if (_deepOpen.isNotEmpty)
            Text('Deep TCP open ports: ${_deepOpen.join(", ")}'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const ValueKey('host-copy-diagnostics'),
            onPressed: _copyReport,
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy device diagnostics'),
          ),
          ScanReportPanel(title: 'Device scan output', report: _report),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            key: const ValueKey('use-host-ip'),
            onPressed: () => Navigator.pop(context, widget.device.ip),
            icon: const Icon(Icons.link_outlined),
            label: const Text('Use this IP for pairing'),
          ),
          const SizedBox(height: 8),
          const Text('Back returns to the network results without rescanning.'),
        ],
      )),
    );
  }
}
