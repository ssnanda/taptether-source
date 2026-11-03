import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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

  /// Microsoft moved official Xbox Remote Play to the browser in 2025.
  /// Keep account sign-in with Microsoft, never capture Xbox credentials.
  Future<void> _openRemotePlay() async {
    try {
      final uri = Uri.parse('https://www.xbox.com/remoteplay');
      final launched = await launchUrl(
          uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        setState(() => _error = 'Unable to open official Xbox Remote Play.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to open official Xbox Remote Play.');
      }
    }
  }

  Future<void> _scan({
    String? ip,
    bool fullNetwork = false,
    bool deepTcp = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _diagnostics = null;
      _scanProgress = fullNetwork
          ? deepTcp ? 'Preparing optional deep network diagnostics…'
              : 'Searching Xbox UDP 5050 across this Wi-Fi…'
          : 'Checking Xbox IP ${ip ?? ""}…';
      _message = fullNetwork ? 'Searching the active Wi-Fi for Xbox…'
          : 'Checking the selected Xbox address…';
    });
    try {
      if (ip != null) {
        await _store.saveLastTargetIp(ip);
      }
      final XboxNetworkReport? report;
      final List<XboxConsole> results;
      if (widget.discovery != null && !fullNetwork) {
        report = null;
        results = await widget.discovery!(targetIp: ip);
      } else {
        report = await runXboxNetworkDiagnostics(
          targetIp: ip,
          fullNetwork: fullNetwork,
          deepTcp: deepTcp,
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
        final replies = report?.udpStats.observed ?? const [];
        _message = results.isNotEmpty
            ? 'Discovered ${results.length} Xbox via legacy SmartGlass '
                '(not authenticated).'
            : replies.isNotEmpty
                ? 'UDP 5050 answered, but the reply is not compatible: '
                    '${replies.first.diagnosis.reason}. See diagnostics.'
                : fullNetwork
                    ? 'No compatible legacy Xbox response anywhere on Wi-Fi.'
                    : 'No Xbox discovery response from $ip.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _scanProgress = null;
        });
      }
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

  Future<void> _scanFullNetwork({bool deepTcp = false}) async {
    final ip = _ip.text.trim();
    if (ip.isNotEmpty && !isPrivateIPv4(ip)) {
      setState(() => _error = 'Correct the Xbox IP or clear it first.');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await _scan(
        fullNetwork: true, deepTcp: deepTcp,
        ip: ip.isEmpty ? null : ip);
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
      appBar: AppBar(title: const Text('Xbox')),
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
            label: const Text('Find Xbox across this Wi-Fi'),
          ),
          TextButton.icon(
            onPressed: _busy ? null
                : () => _scanFullNetwork(deepTcp: true),
            icon: const Icon(Icons.bug_report_outlined, size: 18),
            label: const Text('Deep network diagnostics (slower)'),
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
                    label: const Text('Check Xbox IP'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _openRemotePlay,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Xbox Remote Play'),
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
          const Text('Legacy LAN discovery and Xbox wake use UDP 5050. '
              'They do not provide authenticated controller buttons. '
              'Xbox Remote Play opens Microsoft’s official browser app, '
              'where you sign in and select your console.'),
          if (selected == null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openRemotePlay,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Open Xbox Remote Play'),
            ),
          ],
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
        Row(children: [
          Expanded(child: Text('Network diagnostics',
              style: Theme.of(context).textTheme.titleMedium)),
          IconButton(
            tooltip: 'Copy diagnostics',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(
                  text: formatXboxNetworkDiagnostics(report)));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Network diagnostics copied')),
                );
              }
            },
            icon: const Icon(Icons.copy_outlined),
          ),
        ]),
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
        if (report.udpStats.observed.isNotEmpty)
          ExpansionTile(
            key: const ValueKey('xbox-udp-reply-diagnostics'),
            tilePadding: EdgeInsets.zero,
            initiallyExpanded: true,
            title: const Text('UDP reply analysis'),
            subtitle: const Text('Exact rejection reasons; header only'),
            children: [
              for (final reply in report.udpStats.observed)
                ListTile(
                  dense: true,
                  title: Text('${reply.host}:${reply.sourcePort}'),
                  subtitle: Text('${reply.diagnosis.summary}\n'
                      'Header: ${reply.diagnosis.headerHex}'),
                ),
            ],
          ),
        if (report.targetIp != null) ...[
          const SizedBox(height: 6),
          Text('Target ${report.targetIp}: '
              '${report.targetDiscovered ? "Legacy Xbox identified "
                  "(not authenticated)" :
                  report.udpStats.repliesFrom(report.targetIp!).isNotEmpty
                      ? "UDP reply received; Xbox not confirmed"
                      : "No Xbox discovery reply"}'),
          Text(ports.isEmpty ? 'TCP tests unavailable' : ports),
        ],
        if (report.tcpSweepPerformed)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('TCP-visible hosts: ${report.tcpHosts.length}'),
            subtitle: const Text('Only devices with open tested TCP ports'),
            children: [
              for (final host in report.tcpHosts)
                ListTile(
                  dense: true,
                  title: Text(host.ip),
                  subtitle: Text('TCP ${host.openPorts.join(", ")}'),
                  onTap: () => setState(() => _ip.text = host.ip),
                ),
            ],
          ),
        if (report.truncated)
          const Text('Large network: only the first four /24 blocks '
              'were scanned (up to 1,024 addresses).'),
        const SizedBox(height: 8),
        const Text('TCP ports do not identify an Xbox. Legacy SmartGlass '
            'control sessions require encrypted authentication. '
            'For current remote control, use the official Xbox Remote Play '
            'button above.'),
      ]),
    ));
  }

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }
}