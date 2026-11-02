import 'dart:async';

import 'package:flutter/material.dart';

import 'govee_api.dart';

/// Govee Home integration using Govee's published developer API.
/// The only saved credential is the user's API key, in iOS Keychain.
class GoveeScreen extends StatefulWidget {
  const GoveeScreen({super.key, this.settingsOnly = false});
  final bool settingsOnly;

  @override
  State<GoveeScreen> createState() => _GoveeScreenState();
}

class _GoveeScreenState extends State<GoveeScreen> {
  final _connection = GoveeConnection();
  final _keyInput = TextEditingController();
  final _working = <String>{};
  List<GoveeDevice> _devices = GoveeConnection.cachedDevices;
  bool _connected = false;
  bool _loading = true;
  bool _saving = false;
  bool _showKey = false;
  String? _error;
  DateTime? _checked;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _keyInput.dispose();
    _connection.close();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final connected = await _connection.restore();
      if (!mounted) return;
      setState(() {
        _connected = connected;
        _loading = false;
      });
      if (connected) unawaited(_refresh());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read Govee credentials from secure storage.';
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() { _saving = true; _error = null; });
    try {
      await _connection.saveKey(_keyInput.text);
      if (!mounted) return;
      setState(() {
        _connected = true;
        _keyInput.clear();
        _showKey = false;
      });
      await _refresh();
    } on GoveeApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save Govee API key.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await _connection.disconnect();
      if (!mounted) return;
      setState(() {
        _devices = [];
        _connected = false;
        _error = null;
        _checked = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not remove saved Govee key.');
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final devices = await _connection.devices();
      if (!mounted) return;
      setState(() { _devices = devices; _checked = DateTime.now(); });
      // A failed status query never hides otherwise controllable devices.
      // Serial queries avoid saturating an account with concurrent requests.
      for (final device in devices) {
        if (!mounted) return;
        try {
          final live = await _connection.updateState(device);
          if (!mounted) return;
          setState(() => _replace(live));
        } catch (_) {
          // The API may omit state support on older devices.
        }
      }
    } on GoveeApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Unable to refresh Govee devices.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _replace(GoveeDevice updated) {
    _devices = [
      for (final d in _devices) d.id == updated.id ? updated : d,
    ];
  }

  Future<void> _command(GoveeDevice device, Future<void> Function() send,
      GoveeDevice optimistic) async {
    if (_working.contains(device.id) || device.online == false) return;
    setState(() { _working.add(device.id); _replace(optimistic); _error = null; });
    try {
      await send();
    } on GoveeApiException catch (error) {
      if (mounted) setState(() { _replace(device); _error = error.message; });
    } catch (_) {
      if (mounted) setState(() {
        _replace(device);
        _error = 'Govee command failed. Try again.';
      });
    } finally {
      if (mounted) setState(() => _working.remove(device.id));
    }
  }

  Future<void> _updateBrightness(GoveeDevice device, double value) {
    final next = value.round().clamp(1, 100).toInt();
    return _command(device,
      () => _connection.brightness(device, next),
      device.withLocal(brightness: next));
  }

  Widget _credentialPanel(ThemeData theme) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.key_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(
            _connected ? 'Govee account connected' : 'Connect Govee Home',
            style: theme.textTheme.titleMedium)),
          if (_connected) const Icon(Icons.check_circle, color: Colors.green),
        ]),
        const SizedBox(height: 8),
        if (!_connected || _showKey) ...[
          const Text('In Govee Home: Profile → Settings → Apply for API Key. '
              'Govee emails the key to your account. No password is needed.'),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('govee-api-key'),
            controller: _keyInput,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Govee Developer API Key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _saving || _keyInput.text.trim().isEmpty ? null : _save,
            icon: const Icon(Icons.link),
            label: Text(_saving ? 'Connecting…' : 'Save & connect'),
          ),
        ] else ...[
          const Text('Official Govee API • encrypted credential storage on this phone'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            TextButton.icon(
              onPressed: () => setState(() => _showKey = true),
              icon: const Icon(Icons.key_outlined),
              label: const Text('Replace key')),
            TextButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              label: const Text('Disconnect')),
          ]),
        ],
      ]),
    ),
  );

  Widget _deviceCard(ThemeData theme, GoveeDevice device) {
    final busy = _working.contains(device.id);
    final available = !busy && device.online != false;
    final colors = <int>[
      0xfff44336, 0xffff9800, 0xffffeb3b, 0xff4caf50,
      0xff00bcd4, 0xff2196f3, 0xff9c27b0, 0xffffffff,
    ];
    final scenes = device.capability('devices.capabilities.dynamic_scene', 'lightScene')?.options ?? const <(String, int)>[];
    return Card(
      key: ValueKey('govee-device-${device.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              backgroundColor: device.isLight
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.secondaryContainer,
              child: Icon(device.isLight ? Icons.lightbulb_rounded
                  : Icons.devices_other_rounded),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium),
                Text(
                  device.online == false ? 'Offline · ${device.sku}'
                    : device.online == true ? 'Online · ${device.sku}'
                    : 'Govee · ${device.sku}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            )),
            if (busy) const SizedBox(height: 18, width: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
            if (device.hasPower) Switch.adaptive(
              value: device.powered ?? false,
              onChanged: available ? (on) => _command(device,
                () => _connection.power(device, on),
                device.withLocal(powered: on)) : null,
            ),
          ]),
          if (device.hasBrightness) ...[
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.brightness_6_rounded, size: 20),
              const SizedBox(width: 8),
              const Text('Brightness'),
              const Spacer(),
              Text('${device.brightness ?? 50}%'),
            ]),
            Slider(
              value: (device.brightness ?? 50).clamp(1, 100).toDouble(),
              min: 1, max: 100,
              onChanged: available ? (v) => setState(() =>
                _replace(device.withLocal(brightness: v.round()))) : null,
              onChangeEnd: available ? (v) => _updateBrightness(device, v) : null,
            ),
          ],
          if (device.hasColor) ...[
            const Text('Color'),
            const SizedBox(height: 6),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final value in colors)
                InkWell(
                  key: ValueKey('govee-color-${device.id}-$value'),
                  onTap: available ? () => _command(device,
                    () => _connection.rgb(device, value),
                    device.withLocal(color: value)) : null,
                  borderRadius: BorderRadius.circular(50),
                  child: Container(
                    height: 34, width: 34,
                    decoration: BoxDecoration(
                      color: Color(value), shape: BoxShape.circle,
                      border: Border.all(
                        color: device.color == value
                          ? theme.colorScheme.primary : theme.dividerColor,
                        width: device.color == value ? 3 : 1),
                    ),
                  ),
                ),
            ]),
          ],
          if (device.hasTemperature) ...[
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.thermostat_outlined, size: 20),
              const SizedBox(width: 8),
              const Text('White temperature'),
              const Spacer(),
              Text('${device.colorTemperature ?? 4000} K'),
            ]),
            Builder(builder: (context) {
              final info = device.capability(
                'devices.capabilities.color_setting', 'colorTemperatureK');
              final range = info?.parameters['range'];
              final min = range is Map && range['min'] is num
                  ? (range['min'] as num).toDouble() : 2000.0;
              final max = range is Map && range['max'] is num
                  ? (range['max'] as num).toDouble() : 9000.0;
              if (max <= min) return const SizedBox.shrink();
              return Slider(
                value: (device.colorTemperature ?? 4000)
                    .toDouble().clamp(min, max).toDouble(),
                min: min, max: max,
                onChanged: available ? (v) => setState(() =>
                  _replace(device.withLocal(colorTemperature: v.round()))) : null,
                onChangeEnd: available ? (v) => _command(device,
                  () => _connection.temperature(device, v.round()),
                  device.withLocal(colorTemperature: v.round())) : null,
              );
            }),
          ],
          if (scenes.isNotEmpty) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              key: ValueKey('govee-scenes-${device.id}'),
              decoration: const InputDecoration(
                labelText: 'Scene', border: OutlineInputBorder(),
                isDense: true),
              initialValue: scenes.any((s) => s.$2 == device.scene) ? device.scene : null,
              items: [
                for (final entry in scenes)
                  DropdownMenuItem(value: entry.$2, child: Text(entry.$1,
                      overflow: TextOverflow.ellipsis)),
              ],
              onChanged: available ? (value) {
                if (value != null) unawaited(_command(device,
                  () => _connection.scene(device, value),
                  device.withLocal(scene: value)));
              } : null,
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.settingsOnly ? 'Govee API' : 'Govee Devices'),
        actions: [
          IconButton(
            tooltip: 'Refresh Govee devices',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _connected && !_loading ? _refresh : null),
        ],
      ),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _credentialPanel(theme),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: TextStyle(
                color: theme.colorScheme.error)),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_connected) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Text('Your devices', style: theme.textTheme.titleLarge),
                const Spacer(),
                Text('${_devices.length}', style: theme.textTheme.titleMedium),
              ]),
            ),
            if (_devices.isEmpty && !_loading)
              const Padding(padding: EdgeInsets.all(20),
                child: Text('No compatible Govee devices found. '
                    'Check the API key and which devices Govee exposes.')),
            for (final device in _devices) _deviceCard(theme, device),
            if (_checked != null) const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Controls are shown only when supported by Govee. '
                  'Device status is refreshed when this page opens or you tap refresh.'),
            ),
          ],
        ],
      )),
    );
  }
}
