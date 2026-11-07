import 'dart:async';

import 'package:flutter/material.dart';
import 'display_time.dart';

import 'govee_api.dart';
import 'govee_placement.dart';

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
  final _placementStore = GoveePlacementStore();
  Map<String, GoveePlacement> _placements = {};
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
      final placements = await _placementStore.read();
      final connected = await _connection.restore();
      if (!mounted) return;
      setState(() {
        _placements = placements;
        _connected = connected;
        if (!connected) _devices = [];
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
      // H5054 sleeping leak sensors use a separate Govee app/gateway feed.
      // The developer API's offline flag would mislabel them. Skip the
      // unsupported poll, and query other supported devices in small batches.
      final queryable = devices.where((d) => d.sku.toUpperCase() != 'H5054')
          .toList();
      for (var start = 0; start < queryable.length; start += 4) {
        if (!mounted) return;
        await Future.wait(queryable.skip(start).take(4).map((device) async {
          try {
            final live = await _connection.updateState(device);
            if (mounted) setState(() => _replace(live));
          } catch (_) {
            // Leave this device's status unknown, never mark it offline.
          }
        }));
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

  Future<void> _organize({GoveeDevice? device}) async {
    final selected = <String>{
      if (device != null) goveeDeviceKey(device),
    };
    final initial = device == null
        ? const GoveePlacement()
        : _placements[goveeDeviceKey(device)] ?? const GoveePlacement();
    final locationInput = TextEditingController(text: initial.location);
    final roomInput = TextEditingController(text: initial.room);
    final answer = await showDialog<({Set<String> ids, GoveePlacement value})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, redraw) => AlertDialog(
          title: Text(device == null
              ? 'Organize IoT devices' : 'Organize ${device.name}'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('govee-location'),
                  controller: locationInput,
                  maxLength: 60,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Location (optional)',
                    hintText: 'Home, Office',
                  ),
                ),
                TextField(
                  key: const ValueKey('govee-room'),
                  controller: roomInput,
                  maxLength: 60,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Room (optional)',
                    hintText: 'Kitchen, Upstairs, Restroom',
                  ),
                ),
                if (device == null) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Apply to selected devices:'),
                  ),
                  SizedBox(
                    height: 235,
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _devices.length,
                      itemBuilder: (_, index) {
                        final item = _devices[index];
                        final id = goveeDeviceKey(item);
                        return CheckboxListTile(
                          key: ValueKey('govee-select-$id'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(item.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                          value: selected.contains(id),
                          onChanged: (checked) => redraw(() {
                            if (checked == true) {
                              selected.add(id);
                            } else {
                              selected.remove(id);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('govee-save-placement'),
              onPressed: selected.isEmpty ? null : () {
                Navigator.pop(dialogContext, (
                  ids: Set<String>.from(selected),
                  value: GoveePlacement(
                    location: locationInput.text.trim(),
                    room: roomInput.text.trim(),
                  ),
                ));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    locationInput.dispose();
    roomInput.dispose();
    if (answer == null || !mounted) return;
    final changed = Map<String, GoveePlacement>.from(_placements);
    for (final id in answer.ids) {
      if (answer.value.isEmpty) {
        changed.remove(id);
      } else {
        changed[id] = answer.value;
      }
    }
    try {
      await _placementStore.save(changed);
      if (mounted) setState(() { _placements = changed; _error = null; });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to save IoT rooms and locations.');
      }
    }
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
      if (mounted) {
        setState(() {
          _replace(device);
          _error = 'Govee command failed. Try again.';
        });
      }
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
              radius: 17,
              backgroundColor: device.isLight
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.secondaryContainer,
              child: Icon(device.isLight ? Icons.lightbulb_rounded
                  : device.isPassiveSensor ? Icons.sensors_rounded
                  : Icons.devices_other_rounded, size: 19),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium),
                Text(
                  '${device.availabilityLabel} · ${device.sku}',
                  maxLines: 2,
                  style: theme.textTheme.bodySmall,
                ),
                if ((_placements[goveeDeviceKey(device)]?.location
                        .isNotEmpty ?? false) &&
                    (_placements[goveeDeviceKey(device)]?.room
                        .isNotEmpty ?? false))
                  Text(
                    'Room: ${_placements[goveeDeviceKey(device)]!.room}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            )),
            IconButton(
              key: ValueKey('govee-edit-${goveeDeviceKey(device)}'),
              icon: const Icon(Icons.edit_outlined, size: 19),
              tooltip: 'Assign location or room to ${device.name}',
              onPressed: () => _organize(device: device),
            ),
            if (busy) const SizedBox(height: 18, width: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
            if (device.hasPower) Switch.adaptive(
              value: device.powered ?? false,
              onChanged: available ? (on) => _command(device,
                () => _connection.power(device, on),
                device.withLocal(powered: on)) : null,
            ),
          ]),
          if (device.sensorTemperature != null ||
              device.sensorHumidity != null) ...[
            const SizedBox(height: 5),
            Wrap(spacing: 12, children: [
              if (device.sensorTemperature != null)
                Text('Temp ${device.sensorTemperature}',
                    style: theme.textTheme.bodySmall),
              if (device.sensorHumidity != null)
                Text('Humidity ${device.sensorHumidity}%',
                    style: theme.textTheme.bodySmall),
            ]),
          ],
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
                if (value != null) {
                  unawaited(_command(device,
                    () => _connection.scene(device, value),
                    device.withLocal(scene: value)));
                }
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
    final groups = goveeGroups(_devices, _placements);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.settingsOnly ? 'Govee API' : 'IoT'),
        actions: [
          if (!widget.settingsOnly)
            IconButton(
              key: const ValueKey('iot-settings'),
              tooltip: 'Govee API settings',
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const GoveeScreen(settingsOnly: true)));
                if (mounted) {
                  setState(() => _loading = true);
                  await _start();
                }
              },
              icon: const Icon(Icons.settings_outlined)),
          if (!widget.settingsOnly)
            IconButton(
              tooltip: 'Refresh IoT devices',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _connected && !_loading ? _refresh : null),
        ],
      ),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (widget.settingsOnly || !_connected)
            _credentialPanel(theme),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(
                color: theme.colorScheme.error)),
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_connected && !widget.settingsOnly) ...[
            Row(children: [
              Expanded(child: Text('Govee · ${_devices.length} devices',
                  style: theme.textTheme.titleMedium)),
              TextButton.icon(
                key: const ValueKey('govee-organize'),
                onPressed: _devices.isEmpty ? null : () => _organize(),
                icon: const Icon(Icons.room_preferences_outlined, size: 18),
                label: const Text('Organize'),
              ),
            ]),
            const Padding(
              padding: EdgeInsets.only(bottom: 9),
              child: Text('Grouped by location, or by room when no location '
                  'is set. Tap the pencil to assign either.'),
            ),
            if (_devices.any((d) => d.sku.toUpperCase() == 'H5054'))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'H5054 leak and battery updates are available in Govee '
                  'Home, not the developer API. Status here is unavailable '
                  'rather than assumed offline.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_devices.isEmpty && !_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No supported Govee devices returned. '
                    'Check your Govee API connection.'),
              ),
            for (final entry in groups.entries)
              Container(
                key: ValueKey('govee-group-${entry.key}'),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.fromLTRB(9, 9, 9, 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  color: theme.colorScheme.surfaceContainerLow,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.location_on_outlined,
                        size: 17, color: theme.colorScheme.primary),
                      const SizedBox(width: 7),
                      Expanded(child: Text(entry.key,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold))),
                      Text('${entry.value.length}',
                        style: theme.textTheme.labelMedium),
                      const SizedBox(width: 8),
                    ]),
                    const SizedBox(height: 8),
                    for (final device in entry.value)
                      _deviceCard(theme, device),
                  ],
                ),
              ),
            if (_checked != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('Latest refresh: ${displayTimeAmPm(_checked!)}. '
                  'Some sensor values are not exposed by the Govee API.',
                  style: theme.textTheme.bodySmall),
              ),
          ],
        ],
      )),
    );
  }
}
