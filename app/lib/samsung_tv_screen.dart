import 'dart:async';
import 'package:flutter/material.dart';

import 'lg_compact_remote.dart';
import 'discovery.dart';
import 'samsung_tv_client.dart';
import 'device_diagnostics_screen.dart';
import 'tv_lan_utils.dart';

/// Samsung Smart View remote. All traffic stays on the current LAN.
class SamsungTvScreen extends StatefulWidget {
  const SamsungTvScreen({
    super.key, this.initialHost, this.initialLocation = 'other',
    this.onSaved, this.autoConnect = true, this.wakeDevice,
  });
  final String? initialHost;
  final String initialLocation;
  final Future<void> Function()? onSaved;
  final bool autoConnect;
  final Future<void> Function(SamsungTvDevice)? wakeDevice;

  @override
  State<SamsungTvScreen> createState() => _SamsungTvScreenState();
}

class _SamsungTvScreenState extends State<SamsungTvScreen> {
  final _store = SamsungTvStore();
  final _ip = TextEditingController();
  List<SamsungTvDevice> _saved = [];
  List<SamsungTvDevice> _discovered = [];
  SamsungTvDevice? _selectedDevice;
  SamsungTvClient? _client;
  bool _busy = false;
  bool _waking = false;
  bool _finding = false;
  String _status = 'Choose a Samsung TV on this Wi-Fi.';
  String? _error;

  bool get _connected => _client?.connected == true;
  bool get _detailMode => widget.initialHost != null;
  // A My Devices detail route may only represent the tapped device.
  // Never fall back to the first saved Samsung TV on another IP.
  SamsungTvDevice? get _selected {
    if (_detailMode) return _selectedDevice;
    return _selectedDevice;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final items = await _store.read();
      if (!mounted) return;
      setState(() => _saved = items);
      if (widget.initialHost != null) {
        final found = items.where((tv) => tv.host == widget.initialHost);
        if (found.isNotEmpty) {
          setState(() {
            _selectedDevice = found.first;
            _status = 'Selected ${found.first.name} · ${found.first.host}';
          });
          if (widget.autoConnect && found.first.token.isNotEmpty) {
            await _connect(found.first);
          }
        } else if (mounted) {
          setState(() {
            _status = 'This TV is no longer saved.';
            _error = 'Return to My Devices to select a saved TV.';
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
          _error = 'Unable to access locally saved Samsung pairings.');
      }
    }
  }

  Future<void> _reload() async {
    final items = await _store.read();
    if (!mounted) return;
    setState(() {
      _saved = items;
      if (_selectedDevice != null) {
        final found = items.where((tv) => tv.host == _selectedDevice!.host);
        if (found.isNotEmpty) _selectedDevice = found.first;
      }
    });
    await widget.onSaved?.call();
  }

  Future<void> _discover() async {
    if (_finding || _busy) return;
    setState(() {
      _finding = true;
      _error = null;
      _status = 'Checking for Samsung TVs on this Wi-Fi…';
    });
    try {
      final results = await discoverSamsungTvs();
      if (!mounted) return;
      setState(() {
        _discovered = results;
        _status = results.isEmpty
            ? 'No compatible Samsung Smart View TV found. Try TV IP.'
            : 'Select a Samsung TV to authorize.';
      });
    } catch (error) {
      if (mounted) {
        setState(() =>
          _error = 'Discovery blocked. Enter the TV LAN IP.');
      }
    } finally {
      if (mounted) {
        setState(() => _finding = false);
      }
    }
  }

  Future<void> _connect(SamsungTvDevice tv) async {
    if (_busy) return;
    if (_detailMode && (_selectedDevice == null ||
        tv.host != _selectedDevice!.host)) {
      return;
    }
    setState(() {
      _selectedDevice = tv;
      _busy = true;
      _error = null;
      _status = tv.token.isEmpty
          ? 'Allow TapTether on the Samsung TV screen.'
          : 'Connecting to Samsung TV…';
    });
    final controller = SamsungTvClient(tv.copyWith(
      location: tv.location == 'other'
          ? widget.initialLocation : tv.location,
    ));
    try {
      await _client?.disconnect();
      _client = null;
      final authorized = await controller.connect();
      await _store.save(authorized);
      if (!mounted) {
        await controller.disconnect();
        return;
      }
      setState(() {
        _client = controller;
        _selectedDevice = authorized;
        _status = 'Connected · ${controller.transport}';
      });
      await _reload();
    } catch (error) {
      await controller.disconnect();
      if (mounted) {
        setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
        _status = 'Not connected';

        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _byIp() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final address = _ip.text.trim();
    if (!isPrivateIPv4(address)) {
      setState(() => _error = 'Enter a private Samsung TV IPv4 address.');
      return;
    }
    final found = _saved.where((tv) => tv.host == address);
    await _connect(found.isEmpty
        ? SamsungTvDevice(host: address, location: widget.initialLocation)
        : found.first);
  }

  void _insertDot() {
    final selection = _ip.selection;
    final start = selection.isValid ? selection.start : _ip.text.length;
    final end = selection.isValid ? selection.end : _ip.text.length;
    _ip.value = TextEditingValue(
      text: _ip.text.replaceRange(start, end, '.'),
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  Future<void> _rename(SamsungTvDevice tv) async {
    final controller = TextEditingController(
      text: tv.name == 'Samsung TV' ? '' : tv.name,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Name Samsung TV'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              hintText: 'Office Display or Family Room TV'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () =>
              Navigator.pop(dialog, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await _store.save(tv.copyWith(name: name));
    await _reload();
  }

  Future<void> _editMac(SamsungTvDevice tv) async {
    final controller = TextEditingController(text: tv.macAddress);
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('TV identity & Power On'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Local address: ${tv.host}'),
          if (tv.model.isNotEmpty) Text('Model: ${tv.model}'),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
                labelText: 'TV Wi-Fi/Ethernet MAC address'),
            autocorrect: false,
          ),
          const SizedBox(height: 8),
          const Text('Power On needs network standby / Power On with '
              'Mobile enabled on compatible Samsung models.',
              style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () =>
              Navigator.pop(dialog, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    final mac = normalizeTvMac(value);
    if (value.isNotEmpty && mac == null) {
      setState(() => _error = 'Enter a valid six-byte MAC address.');
      return;
    }
    await _store.save(tv.copyWith(macAddress: mac ?? ''));
    await _reload();
  }

  /// Always sends Wake-on-LAN to the selected TV only. Background connection
  /// state must never turn an explicit On tap into a Power Off request.
  Future<void> _wakeSelected() async {
    final tv = _selected;
    if (tv == null || _waking) return;
    if (_detailMode && _selectedDevice?.host != tv.host) return;
    _waking = true;
    try {
      await (widget.wakeDevice ?? wakeSamsungTv)(tv);
      if (mounted) {
        setState(() {
          _status = 'Power-on signal sent to ${tv.name} (${tv.host}).';
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      _waking = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _power() async {
    if (_busy) return;
    final selected = _selected;
    if (selected == null) return;
    if (_detailMode && _selectedDevice?.host != selected.host) return;
    if (!_connected || _client?.device.host != selected.host) {
      await _wakeSelected();
      return;
    }
    try {
      await _client!.powerOff();
      await _client!.disconnect();
      if (mounted) {
        setState(() {
          _status = 'Power-off requested for ${selected.name}';
          _client = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _disconnect() async {
    await _client?.disconnect();
    if (mounted) {
      setState(() {
      _client = null;
      _status = 'Disconnected';

      });
    }
  }

  Future<void> _forget(SamsungTvDevice tv) async {
    if (_selected?.host == tv.host) {
      await _disconnect();
      _selectedDevice = null;
    }
    await _store.remove(tv.host);
    await _reload();
    if (_detailMode && mounted) Navigator.of(context).pop();
  }


  Future<void> _showDiagnostics(SamsungTvDevice tv) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeviceDiagnosticsScreen(
        name: tv.name, host: tv.host, kind: 'samsung',
        location: tv.location, paired: tv.token.isNotEmpty,
        hasTlsPin: tv.tlsPin.isNotEmpty,
        reportedOnline: _connected && _selectedDevice?.host == tv.host,
        model: tv.model, lastError: _error,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tv = _selected;
    return Scaffold(
      appBar: AppBar(
        title: Text(tv?.name ??
            (_detailMode ? 'Opening selected Samsung TV…' : 'Samsung TV'),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (tv != null && (!_detailMode || _connected)) TextButton.icon(
            key: const ValueKey('samsung-power-toggle'),
            onPressed: _busy ? null : _power,
            icon: const Icon(Icons.power_settings_new),
            label: Text(_connected ? 'Off' : 'On'),
          ),
          if (tv != null) PopupMenuButton<String>(
            tooltip: 'Samsung TV options',
            onSelected: (item) {
              switch (item) {
                case 'diagnostics': unawaited(_showDiagnostics(tv));
                case 'rename': unawaited(_rename(tv));
                case 'mac': unawaited(_editMac(tv));
                case 'disconnect': unawaited(_disconnect());
                case 'forget': unawaited(_forget(tv));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename TV')),
              const PopupMenuItem(value: 'diagnostics', child: Text('Diagnostics')),
              const PopupMenuItem(value: 'mac',
                  child: Text('TV identity / MAC')),
              if (_connected) const PopupMenuItem(
                  value: 'disconnect', child: Text('Disconnect')),
              const PopupMenuItem(value: 'forget', child: Text('Forget TV')),
            ],
          ),
        ],
      ),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(children: [
          Row(children: [
            Icon(_connected ? Icons.check_circle : Icons.circle_outlined,
                size: 15, color: _connected ? Colors.green : null),
            const SizedBox(width: 8),
            Expanded(child: Text(_status, maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall)),
          ]),
          if (_error != null) Text(_error!,
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error, fontSize: 12)),
          if (_busy || _finding) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          if (_connected && tv != null)
            Expanded(child: LgCompactRemote(
              key: ValueKey('samsung-${tv.deviceId}-${tv.host}'),
              client: _client!, device: tv,
              onError: (error) {
                if (mounted) {
                  setState(() => _error = error);
                }
              },
            ))
          else if (_detailMode)
            Expanded(child: ListView(
              key: const ValueKey('samsung-selected-tv-detail'),
              children: [
                if (tv == null)
                  const Card(child: ListTile(
                    leading: Icon(Icons.tv_off_outlined),
                    title: Text('Selected TV unavailable'),
                    subtitle: Text('Return to My Devices to select a saved TV.'),
                  ))
                else ...[
                  Card(child: ListTile(
                    key: const ValueKey('samsung-selected-tv-card'),
                    leading: const Icon(Icons.tv_outlined, size: 28),
                    title: Text(tv.name),
                    subtitle: Text('IP: ${tv.host}\n'
                      '${_connected ? "Connected" : "Not connected"}'
                      '${tv.macAddress.isEmpty ? "" : " · MAC saved"}'),
                    isThreeLine: true,
                  )),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('samsung-power-selected-tv'),
                    onPressed: _waking ? null : _wakeSelected,
                    icon: const Icon(Icons.power_settings_new),
                    label: Text(_waking
                        ? 'Sending wake signal to ${tv.name}…'
                        : 'Turn on ${tv.name}'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('samsung-connect-selected-tv'),
                    onPressed: _busy ? null : () => _connect(tv),
                    icon: const Icon(Icons.link_outlined),
                    label: Text('Connect to ${tv.name}'),
                  ),
                  const SizedBox(height: 8),
                  Text('Power On sends a wake-up packet only to the saved '
                      'MAC address of this TV. The TV must support '
                      'network standby.',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ))
          else Expanded(child: ListView(children: [
            for (final paired in _saved)
              Card(child: ListTile(
                leading: const Icon(Icons.tv),
                title: Text(paired.name),
                subtitle: Text(paired.host),
                onTap: _busy ? null : () => _connect(paired),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                   IconButton(
                     icon: const Icon(Icons.bug_report_outlined),
                     tooltip: 'Diagnostics',
                     onPressed: () => _showDiagnostics(paired),
                   ),
                   IconButton(
                     icon: const Icon(Icons.edit_outlined),
                     tooltip: 'Rename Samsung TV',
                     onPressed: () => _rename(paired),
                   ),
                 ]),
              )),
            FilledButton.icon(
              onPressed: _busy || _finding ? null : _discover,
              icon: const Icon(Icons.radar),
              label: const Text('Discover Samsung TVs'),
            ),
            for (final candidate in _discovered)
              ListTile(
                leading: const Icon(Icons.tv_outlined),
                title: Text(candidate.model.isNotEmpty
                    ? 'Samsung ${candidate.model}' : 'Samsung Smart TV'),
                subtitle: Text(candidate.host),
                onTap: _busy ? null : () {
                  final old = _saved.where((tv) =>
                      tv.host == candidate.host ||
                      (candidate.deviceId.isNotEmpty &&
                      tv.deviceId == candidate.deviceId));
                  unawaited(_connect(old.isEmpty
                      ? candidate : old.first.copyWith(host: candidate.host)));
                },
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _ip,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true),
              autocorrect: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Samsung TV LAN IP',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Insert IP address dot',
                  onPressed: _insertDot,
                  icon: const Text('.', style: TextStyle(fontSize: 27)),
                ),
              ),
              onSubmitted: (_) => _byIp(),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _byIp,
              icon: const Icon(Icons.link),
              label: const Text('Pair by IP'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: Text('Compatible Tizen Smart View televisions ask '
                'you to Allow TapTether once. Older/commercial Samsung '
                'displays may not expose this remote protocol.',
                style: TextStyle(fontSize: 12)),
            ),
          ])),
        ]),
      )),
    );
  }

  @override
  void dispose() {
    _ip.dispose();
    if (_client != null) unawaited(_client!.disconnect());
    super.dispose();
  }
}
