import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'discovery.dart';
import 'lan_scan.dart';
import 'xbox_smartglass.dart';
import 'xbox_network_diagnostics.dart';
import 'xbox_manual_targets.dart';
import 'xbox_remote_session_screen.dart';

/// TapTether 0.8.77: guided Xbox Remote Play controller proof-of-concept.
/// Connect to Microsoft's actual Xbox Remote Play touch controller.
/// Legacy LAN discovery and SmartGlass wake are optional independent tools.
class XboxRemoteScreen extends StatefulWidget {
  const XboxRemoteScreen({
    super.key,
    this.initialHost,
    this.initialLocation = 'other',
    this.onSaved,
    this.discovery,
    this.wake,
    this.connect,
  });

  final String? initialHost;
  final String initialLocation;
  final Future<void> Function()? onSaved;
  final Future<List<XboxConsole>> Function({String? targetIp})? discovery;
  final Future<void> Function(XboxConsole)? wake;
  final Future<bool> Function()? connect;

  @override
  State<XboxRemoteScreen> createState() => _XboxRemoteScreenState();
}

class _XboxRemoteScreenState extends State<XboxRemoteScreen> {
  final _store = XboxConsoleStore();
  final _manualStore = XboxManualTargetStore();
  final _ip = TextEditingController();
  List<XboxConsole> _saved = [];
  List<XboxManualTarget> _manual = [];
  List<XboxConsole> _found = [];
  XboxConsole? _selected;
  bool _busy = false;
  bool _showDiagnostics = false;
  XboxNetworkReport? _diagnostics;
  String? _scanProgress;
  String _message = '';
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
      final manual = await _manualStore.read();
      if (widget.initialHost == null && _ip.text.trim().isEmpty) {
        _ip.text = await _store.lastTargetIp() ??
            (manual.isNotEmpty ? manual.first.host : '');
      }
      if (!mounted) return;
      setState(() {
        _saved = devices;
        _manual = manual;
        if (widget.initialHost != null) {
          final matches = devices.where((d) => d.host == widget.initialHost);
          if (matches.isNotEmpty) {
            _selected = matches.first;
            _message = '';
          } else if (manual.any((d) => d.host == widget.initialHost)) {
            _message = '';
          }
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot read saved Xbox devices.');
    }
  }

  /// Microsoft's browser handles sign-in and console selection; native
  /// virtual-button delivery remains an experimental page-scoped PoC.
  Future<void> _openRemotePlay() async {
    final host = _ip.text.trim();
    if (_busy || !isPrivateIPv4(host)) return;
    setState(() => _error = null);
    if (widget.connect == null) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => XboxRemoteSessionScreen(host: host),
      ));
      if (!mounted) return;
      setState(() => _message = 'Disconnected');
      return;
    }
    try {
      final launched = await widget.connect!.call();
      if (!mounted) return;
      if (launched) {
        setState(() => _message = 'Opened');
      } else {
        setState(() => _error = 'Unable to open Microsoft Remote Play.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to open Microsoft Remote Play.');
      }
    }
  }

  Future<void> _saveManual() async {
    final host = _ip.text.trim();
    if (!isPrivateIPv4(host)) {
      setState(() => _error = 'Enter the Xbox local IP address first.');
      return;
    }
    final existing = _manual.where((d) => d.host == host);
    final controller = TextEditingController(
      text: existing.isNotEmpty ? existing.first.name : 'Xbox',
    );
    final name = await showDialog<String>(context: context, builder: (context) =>
      AlertDialog(
        title: const Text('Save Xbox'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Address: $host'),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Xbox name'),
          ),
          const SizedBox.shrink(),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(
              context, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    try {
      await _manualStore.save(XboxManualTarget(
        host: host, name: name, location: widget.initialLocation,
      ));
      final targets = await _manualStore.read();
      if (!mounted) return;
      setState(() {
        _manual = targets;
        _error = null;
        _message = 'Saved';
      });
      await widget.onSaved?.call();
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            error.toString().replaceFirst('FormatException: ', ''));
      }
    }
  }

  Future<void> _forgetManual(String host) async {
    if (_busy) return;
    try {
      await _manualStore.remove(host);
      final targets = await _manualStore.read();
      if (!mounted) return;
      setState(() {
        _manual = targets;
        _error = null;
        _message = 'Removed';
      });
      await widget.onSaved?.call();
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Unable to remove this saved Xbox address.');
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
      _message = 'Scanning…';
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
        _message = results.isNotEmpty
            ? 'Found ${results.length} Xbox ${results.length == 1 ? 'device' : 'devices'}'
            : 'No Xbox found';
        if (results.isNotEmpty) {
          _selected = results.first;
          _ip.text = results.first.host;
        }
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
        _message = 'Saved';
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
        _message = 'Removed';
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
    final validIp = isPrivateIPv4(_ip.text.trim());
    return Scaffold(
      appBar: AppBar(title: const Text('Xbox'), actions: [
        IconButton(
          key: const ValueKey('xbox-diagnostics-toggle'),
          icon: const Icon(Icons.tune_rounded),
          tooltip: 'Diagnostics',
          onPressed: () => setState(() =>
              _showDiagnostics = !_showDiagnostics),
        ),
      ]),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
        children: [
          TextField(
            controller: _ip,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Xbox IP',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {
              _selected = null;
              _error = null;
            }),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              key: const ValueKey('xbox-scan'),
              onPressed: _busy ? null : () => _scanFullNetwork(),
              icon: const Icon(Icons.radar_rounded, size: 18),
              label: const Text('Scan'),
            )),
            const SizedBox(width: 7),
            Expanded(child: FilledButton.icon(
              key: const ValueKey('xbox-connect'),
              onPressed: _busy || !validIp ? null : _openRemotePlay,
              icon: const Icon(Icons.gamepad_rounded, size: 18),
              label: const Text('Connect'),
            )),
            const SizedBox(width: 7),
            Expanded(child: OutlinedButton.icon(
              key: const ValueKey('xbox-save-manual'),
              onPressed: _busy || !validIp ? null : _saveManual,
              icon: const Icon(Icons.bookmark_outline_rounded, size: 18),
              label: const Text('Save'),
            )),
          ]),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(_scanProgress ?? 'Scanning…'),
          ],
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          if (_message.isNotEmpty && _error == null) Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_message, key: const ValueKey('xbox-status')),
          ),
          if (_showDiagnostics) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              TextButton.icon(
                onPressed: _busy || !validIp ? null : _byIp,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('Check IP'),
              ),
              TextButton.icon(
                onPressed: _busy ? null
                    : () => _scanFullNetwork(deepTcp: true),
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: const Text('Deep scan'),
              ),
            ]),
            if (_diagnostics != null) _networkDiagnostics(_diagnostics!),
          ],
          if (selected != null) Card(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.sports_esports_rounded),
              title: Text(selected.name),
              subtitle: Text(selected.host),
              trailing: PopupMenuButton<String>(
                tooltip: 'Xbox options',
                onSelected: (action) {
                  if (action == 'save') unawaited(_save(selected));
                  if (action == 'wake') unawaited(_wake());
                  if (action == 'forget') unawaited(_forget());
                },
                itemBuilder: (_) => [
                  if (!saved) const PopupMenuItem(
                    value: 'save', child: Text('Save')),
                  if (saved && selected.liveId.isNotEmpty)
                    const PopupMenuItem(value: 'wake', child: Text('Wake')),
                  if (saved) const PopupMenuItem(
                    value: 'forget', child: Text('Forget')),
                ],
              ),
              onTap: () => setState(() => _ip.text = selected.host),
            ),
          ),
          if (widget.initialHost == null) ...[
            if (_manual.isNotEmpty || _saved.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 5),
                child: Text('Saved',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
            for (final target in _manual)
              ListTile(
                key: ValueKey('xbox-manual-' + target.host),
                dense: true,
                leading: const Icon(Icons.sports_esports_rounded),
                title: Text(target.name),
                subtitle: Text(target.host),
                onTap: () => setState(() {
                  _ip.text = target.host;
                  _selected = null;
                  _message = '';
                }),
                trailing: IconButton(
                  tooltip: 'Forget ' + target.name,
                  onPressed: () => _forgetManual(target.host),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            for (final device in _saved)
              if (!_manual.any((item) => item.host == device.host))
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.sports_esports_rounded),
                  title: Text(device.name),
                  subtitle: Text(device.host),
                  onTap: () => setState(() {
                    _selected = device;
                    _ip.text = device.host;
                    _message = '';
                  }),
                ),
          ],
          for (final device in _found)
            if (selected == null || device.host != selected.host)
              ListTile(
                dense: true,
                leading: const Icon(Icons.sports_esports_rounded),
                title: Text(device.name),
                subtitle: Text(device.host),
                onTap: () => setState(() {
                  _selected = device;
                  _ip.text = device.host;
                }),
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
        Text('Xbox LAN UDP 5050: ${report.udpStats.sent} probes · '
            '${report.udpStats.replies} replies · '
            '${report.udpStats.compatible} compatible'),
        if (report.udpStats.sentByPath.isNotEmpty)
          Text('Routes tested: ${report.udpStats.sentByPath.entries.map(
            (entry) => '${entry.key} ${entry.value}').join(' · ')}'),
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
              '${report.targetDiscovered ? "Xbox identified "
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
        const Text('TCP timeouts cannot determine whether the Xbox is '
            'online or Remote Features are enabled. Tap Connect Xbox '
            'for the supported authenticated controller.'),
      ]),
    ));
  }

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }
}