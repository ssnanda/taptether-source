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
  final _setupStore = XboxRemoteSetupStore();
  final _ip = TextEditingController();
  bool _remoteFeaturesReady = false;
  List<XboxConsole> _saved = [];
  List<XboxManualTarget> _manual = [];
  List<XboxConsole> _found = [];
  XboxConsole? _selected;
  bool _busy = false;
  XboxNetworkReport? _diagnostics;
  String? _scanProgress;
  String _message = 'Connect with Microsoft Remote Play. Local '
      'discovery is optional and does not sign you in.';
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
      final confirmed = await _setupStore.confirmed(_ip.text.trim());
      if (!mounted) return;
      setState(() {
        _remoteFeaturesReady = confirmed;
        _saved = devices;
        _manual = manual;
        if (widget.initialHost != null) {
          final matches = devices.where((d) => d.host == widget.initialHost);
          if (matches.isNotEmpty) {
            _selected = matches.first;
            _message = 'Saved Xbox — current connection not checked';
          } else if (manual.any((d) => d.host == widget.initialHost)) {
            _message = 'Saved Xbox address — identity not independently '
                'verified. Connect using Microsoft Remote Play.';
          }
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot read saved Xbox devices.');
    }
  }

  Future<void> _restoreRemoteFeatures(String ip) async {
    final confirmed = await _setupStore.confirmed(ip);
    if (!mounted || _ip.text.trim() != ip) return;
    setState(() => _remoteFeaturesReady = confirmed);
  }

  Future<void> _setRemoteFeatures(bool enabled) async {
    final host = _ip.text.trim();
    if (!isPrivateIPv4(host)) {
      setState(() => _error = 'Enter the Xbox IP before confirming setup.');
      return;
    }
    try {
      await _setupStore.setConfirmed(host, enabled);
      if (mounted) {
        setState(() {
          _remoteFeaturesReady = enabled;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Unable to save Xbox setup.');
    }
  }

  /// Microsoft's browser handles sign-in and console selection; native
  /// virtual-button delivery remains an experimental page-scoped PoC.
  Future<void> _openRemotePlay() async {
    final host = _ip.text.trim();
    if (_busy || !isPrivateIPv4(host) || !_remoteFeaturesReady) return;
    setState(() => _error = null);
    if (widget.connect == null) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => XboxRemoteSessionScreen(host: host),
      ));
      if (!mounted) return;
      setState(() => _message = 'Xbox session closed. You can reconnect '
          'without rescanning. Browser controls are experimental.');
      return;
    }
    try {
      final launched = await widget.connect!.call();
      if (!mounted) return;
      if (launched) {
        setState(() => _message = 'Microsoft Remote Play opened. '
            'Sign in and select your Xbox. Console response not verified.');
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
        title: const Text('Save Xbox address'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Address: $host'),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Xbox name'),
          ),
          const Text('Saved manually — the console has not been '
              'authenticated or discovered by TapTether.'),
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
        _message = '$name saved in Devices as an unverified address. '
            'Use Connect Xbox to open authenticated Remote Play.';
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
        _message = 'Saved Xbox address removed.';
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
        final targetMatched = ip == null ||
            results.any((device) => device.host == ip);
        _message = results.isNotEmpty && targetMatched
            ? 'Discovered ${results.length} Xbox via LAN discovery '
                '(not authenticated).'
            : results.isNotEmpty && ip != null
                ? 'No discovery reply from $ip, but an Xbox answered from '
                    '${results.first.host}. Verify which IP belongs to your console.'
                : replies.isNotEmpty
                    ? 'Xbox LAN probe answered but was not compatible: '
                        '${replies.first.diagnosis.reason}. See diagnostics.'
                    : fullNetwork
                        ? 'No Xbox LAN discovery response across this Wi-Fi. '
                          'This does not mean Remote Features is disabled.'
                        : 'No Xbox LAN discovery reply from $ip. '
                          'Remote Features may already be enabled.';
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
              hintText: '192.168.68.82',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() => _remoteFeaturesReady = false);
              unawaited(_restoreRemoteFeatures(value.trim()));
            },
            onSubmitted: (_) => _byIp(),
          ),
          const SizedBox(height: 8),
          Text('1 · Find Xbox or enter its IP',
            style: Theme.of(context).textTheme.titleSmall),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: _busy ? null : _byIp,
              icon: const Icon(Icons.search),
              label: const Text('Check IP'),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _scanFullNetwork(),
              icon: const Icon(Icons.radar),
              label: const Text('Scan Wi-Fi'),
            )),
          ]),
          Text('If Xbox discovery does not reply, use its IP shown on '
              'the console. Scanning is not required to connect.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          CheckboxListTile(
            key: const ValueKey('xbox-remote-features'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('2 · Remote Features enabled'),
            subtitle: const Text('Settings → Devices & connections → '
                'Remote features. Confirm once; TapTether saves it.'),
            value: _remoteFeaturesReady,
            onChanged: _busy ? null :
                (enabled) => _setRemoteFeatures(enabled == true),
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            key: const ValueKey('xbox-connect'),
            onPressed: _busy || !_remoteFeaturesReady ||
                !isPrivateIPv4(_ip.text.trim()) ? null : _openRemotePlay,
            icon: const Icon(Icons.gamepad_rounded),
            label: const Text('3 · Connect & test controller'),
          ),
          const SizedBox(height: 6),
          Text('Microsoft sign-in and console selection are next. '
              'Virtual buttons are an experimental proof of concept, '
              'not verified Xbox pairing.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('xbox-save-manual'),
            onPressed: _busy ? null : _saveManual,
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('Save Xbox to Devices'),
          ),
          const SizedBox(height: 14),
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
                    label: const Text('Connect & test controller'),
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
          const Text('TapTether checks an older Xbox LAN discovery method over '
              'UDP 5050. Remote Features can already be enabled while '
              'the console does not answer those requests. '
              'A TCP timeout does not prove the Xbox is offline.'),
          const SizedBox(height: 6),
          Text('To verify the address, compare it with Xbox Settings → '
              'General → Network settings → Advanced settings → IP address. '
              'For current console access, use Xbox Remote Play and '
              'sign in to your Microsoft account. '
              'Sleep mode is needed only for standby wake.',
              style: Theme.of(context).textTheme.bodySmall),
          if (widget.initialHost == null) ...[
            const SizedBox(height: 12),
            for (final target in _manual) ListTile(
              key: ValueKey('xbox-manual-${target.host}'),
              leading: const Icon(Icons.videogame_asset_outlined),
              title: Text(target.name),
              subtitle: Text('${target.host} · Manually saved, not verified'),
              onTap: _busy ? null : () => setState(() {
                _ip.text = target.host;
                _selected = null;
              }),
              trailing: IconButton(
                tooltip: 'Forget ${target.name}',
                onPressed: _busy ? null : () => _forgetManual(target.host),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
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