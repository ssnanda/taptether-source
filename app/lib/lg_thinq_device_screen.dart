import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lg_thinq_api.dart';
import 'lg_thinq_features.dart';

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

class _LgThinQDeviceScreenState extends State<LgThinQDeviceScreen> {
  final _store = LgThinQStorage();
  bool _busy = true;
  bool _sending = false;
  String? _error;
  String? _warning;
  DateTime? _checked;
  Object? _profile;
  Object? _state;
  List<ThinQFeature> _features = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
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
      } catch (_) {
        warnings.add('Current appliance status is unavailable.');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _profile = profile;
        _state = state;
        _features = thinQFeatures(profile, state);
        _checked = DateTime.now();
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
        ? feature.options.first : null;
    final numeric = TextEditingController(
        text: feature.current is num
            ? feature.current.toString()
            : feature.minimum?.toString() ?? '');
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
                  RadioListTile<Object>(
                    dense: true,
                    title: Text(option is bool
                        ? (option ? 'On' : 'Off')
                        : option.toString().replaceAll('_', ' ')),
                    value: option,
                    groupValue: selection,
                    onChanged: (value) => change(() => selection = value),
                  ),
              ] else ...[
                Text('Range: ${feature.minimum} – ${feature.maximum}'
                    '${feature.unit == null ? "" : " ${feature.unit}"}'
                    ' · step ${feature.step ?? 1}'),
                TextField(
                  key: const ValueKey('thinq-numeric-value'),
                  controller: numeric,
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
                    ? selection : num.tryParse(numeric.text.trim());
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
    numeric.dispose();
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Confirm ${feature.name}'),
        content: Text('Send ${feature.name} = $choice to '
            '${widget.device.name} through LG ThinQ? '
            'For washers and dryers, Remote Start may need to be '
            'armed on the appliance. LG may reject unavailable operations.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('thinq-confirm-control'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Send command')),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
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
    final type = widget.device.type.toUpperCase();
    final icon = type.contains('REFRIGERATOR')
        ? Icons.kitchen_outlined
        : type.contains('DRYER')
            ? Icons.dry_cleaning_outlined
            : Icons.local_laundry_service_outlined;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        actions: [
          IconButton(
            key: const ValueKey('thinq-copy-features'),
            tooltip: 'Copy all feature diagnostics',
            onPressed: _copyDiagnostics,
            icon: const Icon(Icons.copy_all_outlined)),
          IconButton(
            key: const ValueKey('thinq-refresh-status'),
            tooltip: 'Refresh ThinQ features and status',
            onPressed: _busy || _sending ? null : _refresh,
            icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(icon, size: 34),
                  const SizedBox(width: 14),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.device.name,
                          style: Theme.of(context).textTheme.titleLarge),
                      Text(widget.device.model.isEmpty
                          ? 'LG ThinQ appliance' : widget.device.model),
                      const Text('LG ThinQ cloud API'),
                    ],
                  )),
                ]),
                const SizedBox(height: 14),
                Text(thinQSummaryLine(_features),
                    style: Theme.of(context).textTheme.titleMedium),
                if (_checked != null) Text(
                  'Last refreshed: ${_checked!.hour.toString().padLeft(2, "0")}:'
                  '${_checked!.minute.toString().padLeft(2, "0")}',
                    style: Theme.of(context).textTheme.bodySmall),
                if (_busy || _sending)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: LinearProgressIndicator()),
              ],
            ),
          )),
          const SizedBox(height: 6),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (_warning != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_warning!),
            ),
          Row(children: [
            Expanded(child: Text('All reported features (${_features.length})',
                style: Theme.of(context).textTheme.titleMedium)),
            Text('${_features.where((f) => f.actionable).length} controls',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
          const SizedBox(height: 6),
          const Text('Everything reported by LG is listed below. '
            'Controls appear only when LG supplies writable values '
            'or ranges for this model. Unavailable values are labeled.'),
          const SizedBox(height: 8),
          if (!_busy && _features.isEmpty)
            const Card(child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('LG returned no readable features. '
                'Check the device profile/status permissions in your '
                'personal access token, then refresh.'),
            )),
          for (final group in groups.entries)
            Card(child: ExpansionTile(
              key: ValueKey('thinq-group-${group.key}'),
              initiallyExpanded: true,
              title: Text(group.key),
              subtitle: Text('${group.value.length} features · '
                  '${group.value.where((f) => f.actionable).length} controls'),
              children: [
                for (final f in group.value)
                  ListTile(
                    dense: true,
                    title: Text(f.name),
                    subtitle: Text('${f.currentText}'
                        '${f.unit == null ? "" : " ${f.unit}"}'
                        '\n${f.type} · '
                        '${f.actionable ? "Adjustable" :
                            f.writable ? "LG writable (no safe options)" :
                            "Read-only"}'),
                    isThreeLine: true,
                    trailing: f.actionable
                        ? IconButton(
                            key: ValueKey('thinq-control-${f.identity}'),
                            tooltip: 'Change ${f.name}',
                            onPressed: _busy || _sending
                                ? null : () => _control(f),
                            icon: const Icon(Icons.tune))
                        : const Icon(Icons.info_outline, size: 17),
                    onTap: f.actionable && !_busy && !_sending
                        ? () => _control(f) : null,
                  ),
              ],
            )),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _busy || _sending ? null : _refresh,
            icon: const Icon(Icons.sync),
            label: const Text('Refresh all features'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('thinq-copy-report'),
            onPressed: _copyDiagnostics,
            icon: const Icon(Icons.copy),
            label: const Text('Copy complete feature report'),
          ),
          const SizedBox(height: 10),
          const Text('LG controls may require Remote Start to be enabled '
            'on the washer or dryer. TapTether never runs commands '
            'automatically or in the background.'),
        ]),
      ),
    );
  }
}
