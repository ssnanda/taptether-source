import 'dart:async';

import 'package:flutter/material.dart';

import 'discovery.dart';
import 'lan_scan.dart';
import 'xbox_smartglass.dart';
import 'xbox_network_diagnostics.dart';

/// First Xbox remote milestone: LAN discovery, saved consoles and standby wake.
/// Does NOT claim the console is authenticated or that buttons work yet.
class XboxRemoteScreen extends StatefulWidget {
  const XboxRemoteScreen({
    super.key,
    this.initialHost,
    this.initialLocation = 'other',
    this.onSaved,
    this.discovery,
    this.wake,
  });

  final String? initialHost;
  final String initialLocation;
  final Future<void> Function()? onSaved;
  final Future<List<XboxConsole>> Function({String? targetIp})? discovery;
  final Future<void> Function(XboxConsole)? wake;

  @override
  State<XboxRemoteScreen> createState() => _XboxRemoteScreenState();
}

class _XboxRemoteScreenState extends State<XboxRemoteScreen> {
  final _store = XboxConsoleStore();
  final _ip = TextEditingController();
  List<XboxConsole> _saved = [];
  List<XboxConsole> _found = [];
  XboxConsole? _selected;
  bool _busy = false;
  XboxNetworkReport? _diagnostics;
  String? _scanProgress;
  String _message = 'Use the Xbox IP or scan the local Wi-Fi network.';
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialHost != null) {
      _ip.text = widget.initialHost!;
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final devices = await _store.read();
      if (widget.initialHost == null) {
        _ip.text = await _store.lastTargetIp() ?? '';
      }
      if (!mounted) return;
      setState(() {
        _saved = devices;
        if (widget.initialHost != null) {
          final matches = devices.where((d) => d.host == widget.initialHost);
          if (matches.isNotEmpty) {
            _selected = matches.first;
            _message = 'Saved Xbox — status not checked';
          } else {
            _error = 'This Xbox is no longer saved.';
          }
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot read saved Xbox devices.');
    }
  }

  Future<void> _scan({String? ip, bool fullNetwork = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _diagnostics = null;
      _scanProgress = fullNetwork
          ? 'Preparing full local network scan…'
          : 'Checking Xbox IP ${ip ?? ""}…';
      _message = fullNetwork ? 'Scanning the active Wi-Fi subnet…'
          : 'Checking the selected Xbox address…';
    });
    try {
      if (ip != null) await _store.saveLastTargetIp(ip);
      final XboxNetworkReport? report;
      final List<XboxConsole> results;
      if (widget.discovery != null && !fullNetwork) {
        report = null;
        results = await widget.discovery!(targetIp: ip);
      } else {
        report = await runXboxNetworkDiagnostics(
          targetIp: ip,
          fullNetwork: fullNetwork,
          onProgress: (done, total, stage) {
            if (mounted && (done == total || done % 32 == 0)) {
              setState(() => _scanProgress =
                  '$stage · $done / $total addresses');
            }
          },
        );
        results = report.consoleReplies;
      }
      if (!mounted) return;
      final stored = await _store.read();
      if (!mounted) return;
      setState(() {
        _saved = stored;
        _found = results;
        _diagnostics = report;
        _scanProgress = null;
        if (_selected != null) {
          final matches = results.where((item) =>
              item.uuid == _selected!.uuid &&
              item.certificateSha256 == _selected!.certificateSha256);
          if (matches.isNotEmpty) _selected = matches.first;
        }
        _message = results.isNotEmpty
            ? 'Discovered ${results.length} compatible Xbox console(s).'
            : fullNetwork
                ? 'Scan completed. No Xbox legacy protocol reply.'
                : 'No Xbox legacy discovery reply from $ip.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() {
        _busy = false;
        _scanProgress = null;
      });
    }
  }

  Future<void> _byIp() async {
    final ip = _ip.text.trim();
    if (!isPrivateIPv4(ip)) {
      setState(() => _error = 'Enter a valid local IPv4 address.');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await _scan(ip: ip);
  }

  Future<void> _scanFullNetwork() async {
    final ip = _ip.text.trim();
    if (ip.isNotEmpty && !isPrivateIPv4(ip)) {
      setState(() => _error = 'Correct the Xbox IP or clear it first.');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await _scan(fullNetwork: true, ip: ip.isEmpty ? null : ip);
  }


  bool _sameIdentity(XboxConsole a, XboxConsole b) =>
      a.uuid == b.uuid && a.certificateSha256 == b.certificateSha256;

  Future<void> _save(XboxConsole device) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _store.save(device.copyWith(location: widget.initialLocation));
      final stored = await _store.read();
      if (!mounted) return;
      setState(() {
        _selected = stored.firstWhere((e) => e.uuid == device.uuid);
        _saved = stored;
        _message = 'Xbox saved. This is discovery, not controller pairing.';
      });
      await widget.onSaved?.call();
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wake() async {
    if (_busy || _selected == null) return;
    final device = _selected!;
    final stored = _saved.where((saved) => _sameIdentity(saved, device));
    if (stored.isEmpty) {
      setState(() => _error = 'Save the Xbox before sending Wake.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await (widget.wake?.call(device) ?? wakeXbox(device));
      if (mounted) {
        setState(() => _message =
            'Wake packets sent. This does not confirm that Xbox woke up.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    final device = _selected;
    if (device == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _store.remove(device.uuid);
      final stored = await _store.read();
      if (!mounted) return;
      setState(() {
        _saved = stored;
        _selected = null;
        _message = 'Xbox removed from My Devices.';
      });
      await widget.onSaved?.call();
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot remove saved Xbox.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final saved = selected != null &&
        _saved.any((d) => _sameIdentity(d, selected));
    return Scaffold(
      appBar: AppBar(title: const Text('Xbox discovery')),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ip,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Xbox IP address',
              hintText: '192.168.68.84',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _byIp(),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _byIp,
            icon: const Icon(Icons.search),
            label: const Text('Check Xbox IP'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _scanFullNetwork,
            icon: const Icon(Icons.radar),
            label: const Text('Scan entire local network'),
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(_scanProgress ?? 'Checking Wi-Fi…'),
          ],
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          const SizedBox(height: 12),
          Text(_message, style: Theme.of(context).textTheme.bodyMedium),
          if (_diagnostics != null) ...[
            const SizedBox(height: 12),
            _networkDiagnostics(_diagnostics!),
          ],
          const SizedBox(height: 12),
          if (selected != null) Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.videogame_asset_outlined, size: 38),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(selected.name, style:
                            Theme.of(context).textTheme.titleLarge),
                        Text(selected.host),
                      ])),
                  if (saved) const Icon(Icons.bookmark_added_outlined),
                ]),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (!saved) FilledButton.icon(
                    onPressed: _busy ? null : () => _save(selected),
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Save Xbox'),
                  ),
                  if (saved) FilledButton.icon(
                    onPressed: _busy || selected.liveId.isEmpty
                        ? null : _wake,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Wake Xbox'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _scan(ip: selected.host),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check connection'),
                  ),
                  if (saved) TextButton.icon(
                    onPressed: _busy ? null : _forget,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Forget'),
                  ),
                ]),
                const SizedBox(height: 12),
                Text(selected.liveId.isEmpty
                    ? 'Wake unavailable: Xbox did not provide a readable Live ID.'
                    : 'Wake needs Xbox Sleep/network standby enabled.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          )),
          const SizedBox(height: 12),
          const Text('Xbox remote features can be enabled without '
              'the older UDP 5050 protocol being supported. '
              'A TCP response proves only a reachable service, not '
              'Xbox control compatibility.'),
          if (widget.initialHost == null) ...[
            const SizedBox(height: 12),
            for (final device in _saved) ListTile(
              leading: const Icon(Icons.bookmark_outline),
              title: Text(device.name),
              subtitle: Text(device.host),
              onTap: _busy ? null : () =>
                  setState(() => _selected = device),
            ),
          ],
          for (final candidate in _found) ListTile(
            leading: const Icon(Icons.videogame_asset_outlined),
            title: Text(candidate.name),
            subtitle: Text(candidate.host),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : () =>
                setState(() => _selected = candidate),
          ),
        ],
      )),
    );
  }

  Widget _networkDiagnostics(XboxNetworkReport report) {
    final ports = report.targetPorts.entries.map((item) =>
        'TCP ${item.key}: ${tcpProbeLabel(item.value)}').join(' · ');
    return Card(child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Network diagnostics',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('Wi-Fi: ${report.cidr}'),
        if (report.totalAddresses > 0)
          Text('Addresses checked: ${report.checkedAddresses}/'
              '${report.totalAddresses}'),
        Text('Xbox UDP 5050: ${report.udpStats.sent} probes sent · '
            '${report.udpStats.replies} replies · '
            '${report.udpStats.compatible} compatible'),
        if (report.udpStats.malformed > 0)
          Text('Unrecognized UDP replies: ${report.udpStats.malformed}'),
        if (report.targetIp != null) ...[
          const SizedBox(height: 6),
          Text('Target ${report.targetIp}: '
              '${report.targetDiscovered ? "Xbox protocol reply received" : "No Xbox protocol reply"}'),
          Text(ports.isEmpty ? 'TCP tests unavailable' : ports),
        ],
        if (report.totalAddresses > 0) ...[
          const SizedBox(height: 8),
          Text('TCP-visible hosts: ${report.tcpHosts.length}'),
          for (final host in report.tcpHosts.take(40))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${host.ip} · TCP ${host.openPorts.join(", ")}'),
            ),
          if (report.tcpHosts.length > 40)
            Text('Plus ${report.tcpHosts.length - 40} additional hosts'),
        ],
        if (report.truncated)
          const Text('Large network: only the first four /24 blocks '
              'were scanned (up to 1,024 addresses).'),
        const SizedBox(height: 8),
        const Text('No response does not prove a device is offline. '
            'Xbox Remote Play and authenticated controls are not '
            'implemented.'),
      ]),
    ));
  }

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }
}