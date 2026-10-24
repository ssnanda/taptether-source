import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lg_thinq_api.dart';
import 'lg_thinq_cycle_history.dart';
import 'lg_thinq_history_panel.dart';
import 'lg_thinq_energy_panel.dart';
import 'lg_thinq_overview.dart';
import 'lg_thinq_features.dart';
import 'lg_thinq_refrigerator_overview.dart';

/// Full feature inventory for one explicitly enabled ThinQ appliance.
/// Shows every exposed profile resource/property and live status value,
/// including read-only capabilities, missing reports and writable options.
class LgThinQDeviceScreen extends StatefulWidget {
  const LgThinQDeviceScreen({super.key, required this.device,
      this.fetchProfile, this.fetchState, this.sendControl});
  final LgThinQDevice device;

  // Injected for deterministic widget testing; production uses user's PAT.
  final Future<Object?> Function(String id)? fetchProfile;
  final Future<Object?> Function(String id)? fetchState;
  final Future<void> Function(String id, Map<String, Object?> payload)?
      sendControl;

  @override
  State<LgThinQDeviceScreen> createState() =>
      _LgThinQDeviceScreenState();
}

class _LgThinQDeviceScreenState extends State<LgThinQDeviceScreen>
    with WidgetsBindingObserver {
  final _store = LgThinQStorage();
  bool _busy = true;
  bool _sending = false;
  String? _error;
  String? _warning;
  DateTime? _checked;
  Object? _profile;
  Object? _state;
  List<ThinQFeature> _features = const [];
  final _historyStore = ThinQCycleHistoryStore();
  List<ThinQCycleEntry> _history = const [];
  Timer? _poll;
  bool _foreground = true;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _historyStore.read(widget.device.id).then((entries) {
      if (mounted && _history.isEmpty) {
        setState(() => _history = entries);
      }
    });
    _poll = Timer.periodic(const Duration(seconds: 45), (_) {
      if (mounted && _foreground && !_busy && !_sending) {
        _refresh();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && mounted && !_busy && !_sending) {
      _refresh();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<LgThinQClient> _client() async {
    final token = await _store.token();
    if (token == null || token.isEmpty) {
      throw StateError('LG ThinQ is disconnected. Reconnect in API Integrations.');
    }
    return LgThinQClient(
      personalToken: token,
      country: await _store.country(),
      clientId: await _store.clientId(),
    );
  }

  Future<void> _refresh() async {
    if (_sending) {
      return;
    }
    setState(() { _busy = true; _error = null; _warning = null; });
    try {
      // Profile and state can fail independently. Keep the other result
      // available rather than pretending all features vanished.
      final client = widget.fetchProfile != null &&
              widget.fetchState != null ? null : await _client();
      Object? profile = _profile, state = _state;
      var freshStatus = false;
      final warnings = <String>[];
      try {
        profile = await (widget.fetchProfile != null
            ? widget.fetchProfile!(widget.device.id)
            : client!.profile(widget.device.id));
      } catch (_) {
        warnings.add('Device capabilities could not be refreshed.');
      }
      try {
        state = await (widget.fetchState != null
            ? widget.fetchState!(widget.device.id)
            : client!.state(widget.device.id));
        freshStatus = true;
      } catch (_) {
        warnings.add('Current appliance status is unavailable.');
      }
      if (!mounted) {
        return;
      }
      final items = thinQFeatures(profile, state);
      final now = DateTime.now();
      // Only successful fresh state readings may create history.
      if (freshStatus && (widget.device.type.toUpperCase().contains('WASHER') ||
          widget.device.type.toUpperCase().contains('DRYER'))) {
        try {
          _history = await _historyStore.record(
              widget.device.id, items, now);
        } catch (_) {
          // History persistence never blocks live monitoring.
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _profile = profile;
        _state = state;
        _features = items;
        if (freshStatus) {
          _checked = now;
        }
        _warning = warnings.isEmpty ? null : warnings.join(' ');
        if (warnings.length == 2) {
          _error = 'LG ThinQ did not respond. '
              'Check internet, token permissions and LG service.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Cannot access LG ThinQ. Reconnect your account '
            'under Settings & More → API Integrations.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Object?> _chooseValue(ThinQFeature feature) async {
    Object? selection = feature.options.isNotEmpty
        ? (feature.options.contains(feature.current)
            ? feature.current : feature.options.first)
        : null;
    // Let TextFormField own its controller through the dialog exit animation.
    // Disposing a controller as soon as showDialog resolves is too early.
    var numericValue = feature.current is num
        ? feature.current.toString()
        : feature.minimum?.toString() ?? '';
    final result = await showDialog<Object>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, change) => AlertDialog(
          title: Text(feature.name),
          content: SingleChildScrollView(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(feature.group),
              const SizedBox(height: 8),
              Text('Current: ${feature.currentText}'
                  '${feature.unit == null ? "" : " ${feature.unit}"}'),
              const SizedBox(height: 12),
              if (feature.options.isNotEmpty) ...[
                for (final option in feature.options)
                  ListTile(
                    dense: true,
                    leading: Icon(selection == option
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
                    title: Text(option is bool
                        ? (option ? 'On' : 'Off')
                        : option.toString().replaceAll('_', ' ')),
                    onTap: () => change(() => selection = option),
                  ),
              ] else ...[
                Text('Range: ${feature.minimum} – ${feature.maximum}'
                    '${feature.unit == null ? "" : " ${feature.unit}"}'
                    ' · step ${feature.step ?? 1}'),
                TextFormField(
                  key: const ValueKey('thinq-numeric-value'),
                  initialValue: numericValue,
                  onChanged: (text) => numericValue = text,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true),
                  decoration: const InputDecoration(
                    labelText: 'New value', border: OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: 12),
              const Text('LG must support this command for this model '
                  'and current operating state. Commands can change '
                  'physical appliance operation.',
                  style: TextStyle(fontSize: 12)),
            ],
          )),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('thinq-choose-control'),
              onPressed: () {
                final chosen = feature.options.isNotEmpty
                    ? selection : num.tryParse(numericValue.trim());
                if (chosen == null || !feature.permits(chosen)) {
                  ScaffoldMessenger.of(dialog).showSnackBar(
                    const SnackBar(content:
                      Text('Choose a value permitted by LG.')));
                  return;
                }
                Navigator.pop(dialog, chosen);
              },
              child: const Text('Review command')),
          ],
        ),
      ),
    );
    return result;
  }

  Future<void> _control(ThinQFeature feature) async {
    if (_sending || _busy || !feature.actionable) {
      return;
    }
    final choice = await _chooseValue(feature);
    if (!mounted || choice == null) {
      return;
    }
    await _submitControl(feature, choice);
  }

  bool _quickRefrigeratorControl(ThinQFeature feature) {
    if (!widget.device.type.toUpperCase().contains('REFRIGERATOR')) {
      return false;
    }
    return (feature.resource == 'temperatureInUnits' &&
            const {'targetTemperatureF', 'targetTemperatureC'}
                .contains(feature.property) &&
            const {'FRIDGE', 'FREEZER'}.contains(feature.location)) ||
        (feature.resource == 'refrigeration' &&
            const {'expressMode', 'freshAirFilter'}
                .contains(feature.property));
  }

  /// One sheet, one Apply. The control is still checked against the newest
  /// LG model profile just before transmission.
  Future<void> _editRefrigeratorSetpoint(ThinQFeature feature) async {
    if (_busy || _sending || !feature.actionable ||
        feature.current is! num ||
        feature.minimum == null || feature.maximum == null) {
      return;
    }
    final minimum = feature.minimum!;
    final increment = feature.step ?? 1;
    final divisions = ((feature.maximum! - minimum) / increment).round();
    if (increment <= 0 || divisions < 1 || divisions > 200) return;
    var index = (((feature.current as num) - minimum) / increment)
        .round().clamp(0, divisions).toInt();
    final unit = feature.property.endsWith('F') ? '°F' : '°C';
    num numberAt(int position) {
      final value = minimum + position * increment;
      return value == value.roundToDouble() ? value.toInt() : value;
    }
    final chosen = await showModalBottomSheet<num>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) {
          final current = numberAt(index);
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(feature.location == 'FREEZER'
                      ? 'Freezer temperature' : 'Fridge temperature',
                      style: Theme.of(sheet).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text('Setpoint · ${numberAt(0)}$unit to '
                      '${numberAt(divisions)}$unit',
                      style: Theme.of(sheet).textTheme.bodySmall),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton.filledTonal(
                        key: const ValueKey('thinq-sheet-minus'),
                        icon: const Icon(Icons.remove),
                        onPressed: index == 0 ? null
                            : () => update(() => index--),
                      ),
                      Text('$current$unit',
                          key: const ValueKey('thinq-sheet-value'),
                          style: Theme.of(sheet).textTheme.displaySmall),
                      IconButton.filledTonal(
                        key: const ValueKey('thinq-sheet-plus'),
                        icon: const Icon(Icons.add),
                        onPressed: index == divisions ? null
                            : () => update(() => index++),
                      ),
                    ],
                  ),
                  Slider(
                    key: const ValueKey('thinq-sheet-slider'),
                    value: index.toDouble(),
                    min: 0, max: divisions.toDouble(),
                    divisions: divisions,
                    label: '$current$unit',
                    onChanged: (value) =>
                        update(() => index = value.round()),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${numberAt(0)}$unit'),
                      Text('${numberAt(divisions)}$unit'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('thinq-apply-setpoint'),
                    onPressed: current == feature.current ||
                            !feature.permits(current)
                        ? null : () => Navigator.pop(sheet, current),
                    child: const Text('Apply temperature'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (chosen != null && mounted) {
      await _submitControl(feature, chosen, skipConfirmation: true);
    }
  }

  Future<void> _submitControl(ThinQFeature feature, Object choice,
      {bool skipConfirmation = false}) async {
    if (_sending || _busy || !feature.permits(choice)) {
      return;
    }
    if (!skipConfirmation || !_quickRefrigeratorControl(feature)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Confirm ${feature.name}'),
          content: Text('Send ${feature.name} = $choice to '
              '${widget.device.name} through LG ThinQ? '
              'Remote Start may need to be armed on the appliance.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('thinq-confirm-control'),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Send command')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() { _sending = true; _error = null; });
    try {
      // Revalidate against a fresh profile before every physical command.
      final api = widget.fetchProfile != null &&
              widget.sendControl != null ? null : await _client();
      final latestProfile = await (widget.fetchProfile != null
          ? widget.fetchProfile!(widget.device.id)
          : api!.profile(widget.device.id));
      final fresh = thinQFeatures(latestProfile, _state)
          .where((f) => f.identity == feature.identity &&
              f.permits(choice)).toList();
      if (fresh.length != 1) {
        throw StateError('LG no longer advertises this control/value.');
      }
      final payload = fresh.single.command(choice);
      if (widget.sendControl != null) {
        await widget.sendControl!(widget.device.id, payload);
      } else {
        await api!.control(widget.device.id, payload);
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('LG accepted the command. '
            'Refresh status to confirm the appliance changed.')));
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is StateError
            ? error.message.toString()
            : 'LG could not apply the requested control.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    if (mounted) await _refresh();
  }

  Future<void> _clearHistory() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Clear local cycle history?'),
        content: const Text('This clears observations saved by TapTether '
            'for this appliance only. It does not affect LG ThinQ '
            'history or any washer settings.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (proceed != true || !mounted) {
      return;
    }
    await _historyStore.clear(widget.device.id);
    if (mounted) {
      setState(() => _history = const []);
    }
  }

  Future<void> _copyDiagnostics() async {
    final text = StringBuffer()
      ..writeln('TapTether ThinQ feature diagnostics')
      ..writeln('Appliance: ${widget.device.name}')
      ..writeln('Type: ${widget.device.type}')
      ..writeln('Model identifier: ${widget.device.model}')
      ..writeln('Fields: ${_features.length}')
      ..writeln('Read-only snapshot; no token, account or device IDs.');
    for (final feature in _features) {
      text.writeln('${feature.group} / ${feature.name}: '
          '${feature.currentText} · '
          '${feature.writable ? "writable" : "read-only"} · '
          '${feature.type}'
          '${feature.options.isEmpty ? "" :
              " · choices: ${feature.options.join(", ")}"}'
          '${feature.minimum == null ? "" :
              " · range ${feature.minimum} to ${feature.maximum}"}');
    }
    await Clipboard.setData(ClipboardData(text: text.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Feature report copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<ThinQFeature>>{};
    for (final feature in _features) {
      groups.putIfAbsent(feature.group, () => []).add(feature);
    }
    final refrigerator = widget.device.type.toUpperCase().contains('REFRIGERATOR');
    final laundry = widget.device.type.toUpperCase().contains('WASHER') ||
        widget.device.type.toUpperCase().contains('DRYER');
    final icon = widget.device.type.toUpperCase().contains('REFRIGERATOR')
        ? Icons.kitchen_outlined
        : widget.device.type.toUpperCase().contains('DRYER')
            ? Icons.dry_cleaning_outlined
            : Icons.local_laundry_service_outlined;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        actions: [
          IconButton(
            key: const ValueKey('thinq-copy-features'),
            tooltip: 'Copy full diagnostics',
            onPressed: _copyDiagnostics,
            icon: const Icon(Icons.copy_outlined)),
          IconButton(
            key: const ValueKey('thinq-refresh-status'),
            tooltip: 'Refresh ThinQ status',
            onPressed: _busy || _sending ? null : _refresh,
            icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!refrigerator) Row(children: [
              Icon(icon, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.device.model.isEmpty
                      ? 'LG ThinQ' : widget.device.model,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text('Connected through LG ThinQ · Cloud',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              )),
            ]),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                key: const ValueKey('thinq-detail-tabs'),
                segments: [
                  const ButtonSegment(value: 0,
                      icon: Icon(Icons.home_outlined),
                      label: Text('Overview')),
                  if (laundry)
                    const ButtonSegment(value: 1,
                        icon: Icon(Icons.history),
                        label: Text('History')),
                  const ButtonSegment(value: 2,
                      icon: Icon(Icons.tune),
                      label: Text('Features')),
                ],
                selected: {_tab},
                onSelectionChanged: (next) {
                  setState(() => _tab = next.first);
                },
              ),
            ),
            const SizedBox(height: 13),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(
                color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 9),
            ],
            if (_warning != null) ...[
              Text(_warning!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 9),
            ],
            if (_busy && _features.isEmpty)
              const LinearProgressIndicator(),
            if (_tab == 0 && refrigerator)
              LgThinQRefrigeratorOverview(
                features: _features,
                checked: _checked,
                refreshing: _busy || _sending,
                onRefresh: _refresh,
                onCommand: (feature, choice) => _submitControl(
                    feature, choice, skipConfirmation: true),
                onEdit: _editRefrigeratorSetpoint,
              )
            else if (_tab == 0)
              LgThinQOverview(
                deviceName: widget.device.name,
                deviceType: widget.device.type,
                features: _features,
                checked: _checked,
                refreshing: _busy || _sending,
                onRefresh: _refresh,
                onCommand: _submitControl,
                onSchedule: _control,
              )
            else if (_tab == 1 && laundry)
              LgThinQHistoryPanel(
                history: _history,
                reportedCycleCount:
                    thinQInteger(_features, 'cycleCount'),
                onClear: _clearHistory,
                energy: LgThinQEnergyPanel(device: widget.device),
              )
            else ...[
              Row(children: [
                Expanded(child: Text(
                  'Device features (${_features.length})',
                  style: Theme.of(context).textTheme.titleMedium)),
                Text(
                  '${_features.where((f) => f.actionable).length} controls',
                  style: Theme.of(context).textTheme.bodySmall),
              ]),
              const SizedBox(height: 8),
              Text('All data and writable options LG advertises '
                  'for this model. Tap a section to expand it. '
                  'Unsupported controls remain read-only.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              if (!_busy && _features.isEmpty)
                const Card(child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No feature values returned. '
                      'Refresh or check ThinQ permissions.'),
                )),
              for (final group in groups.entries)
                Card(child: ExpansionTile(
                  key: ValueKey('thinq-group-${group.key}'),
                  initiallyExpanded: false,
                  title: Text(group.key),
                  subtitle: Text('${group.value.length} properties · '
                      '${group.value.where((f) => f.actionable).length} '
                      'adjustable'),
                  children: [
                    for (final item in group.value)
                      ListTile(
                        dense: true,
                        title: Text(item.name),
                        subtitle: Text('${item.currentText}'
                            '${item.unit == null ? "" : " ${item.unit}"}'
                            '\\n${item.type} · ${item.actionable
                                ? "Adjustable"
                                : item.writable
                                    ? "LG writable · no allowed options"
                                    : "Read-only"}'),
                        isThreeLine: true,
                        trailing: item.actionable
                            ? IconButton(
                                key: ValueKey(
                                    'thinq-control-${item.identity}'),
                                tooltip: 'Change ${item.name}',
                                onPressed: _busy || _sending
                                    ? null : () => _control(item),
                                icon: const Icon(Icons.tune))
                            : const Icon(Icons.info_outline, size: 16),
                        onTap: item.actionable && !_busy && !_sending
                            ? () => _control(item) : null,
                      ),
                  ],
                )),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('thinq-copy-report'),
                onPressed: _copyDiagnostics,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy all feature diagnostics'),
              ),
            ],
            const SizedBox(height: 14),
            if (_tab != 2)
              OutlinedButton.icon(
                onPressed: _busy || _sending ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh status'),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
