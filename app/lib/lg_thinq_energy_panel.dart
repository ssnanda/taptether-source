import 'package:flutter/material.dart';

import 'lg_thinq_api.dart';

/// Optional, read-only LG energy usage. No invented energy values.
/// Unsupported models report "not available" rather than zero consumption.
class LgThinQEnergyPanel extends StatefulWidget {
  const LgThinQEnergyPanel({
    super.key,
    required this.device,
    this.fetchProfile,
    this.fetchUsage,
  });

  final LgThinQDevice device;
  final Future<Object?> Function(String id)? fetchProfile;
  final Future<Object?> Function(
      String id, String property, String period,
      String start, String end)? fetchUsage;

  @override
  State<LgThinQEnergyPanel> createState() => _LgThinQEnergyPanelState();
}

class _LgThinQEnergyPanelState extends State<LgThinQEnergyPanel> {
  List<String> _properties = const [];
  String? _selected;
  String _period = 'DAILY';
  List<String> _readings = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh(reloadProfile: true);
  }

  String _date(DateTime date, String period) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return period == 'DAILY' ? '${date.year}$month$day'
        : '${date.year}$month';
  }

  Future<LgThinQClient> _client() async {
    final store = LgThinQStorage();
    final pat = await store.token();
    if (pat == null || pat.isEmpty) {
      throw StateError('LG ThinQ is disconnected.');
    }
    return LgThinQClient(
      personalToken: pat,
      country: await store.country(),
      clientId: await store.clientId(),
    );
  }

  List<String> _profileFields(Object? payload) {
    final root = payload is Map && payload['result'] is Map
        ? payload['result'] : payload;
    if (root is! Map) {
      return const [];
    }
    final props = root['property'];
    if (props is! List) {
      return const [];
    }
    return props.whereType<String>().where((name) =>
        RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,60}$').hasMatch(name))
        .take(24).toList();
  }

  List<String> _summarize(Object? payload) {
    final lines = <String>[];
    const hidden = {
      'deviceid', 'userid', 'serialnumber', 'token',
      'password', 'account', 'locationid', 'macaddress',
    };
    void visit(Object? node, String path, int depth) {
      if (depth > 7 || lines.length > 60) {
        return;
      }
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString();
          if (hidden.contains(key.toLowerCase())) {
            continue;
          }
          visit(entry.value,
              path.isEmpty ? key : '$path / $key', depth + 1);
        }
      } else if (node is List) {
        for (var i = 0; i < node.length && i < 32; i++) {
          visit(node[i], path.isEmpty ? 'Reading ${i + 1}' :
              '$path #${i + 1}', depth + 1);
        }
      } else if (node is num) {
        lines.add('$path: $node');
      }
    }
    visit(payload, '', 0);
    return lines;
  }

  Future<void> _refresh({bool reloadProfile = false}) async {
    if (!mounted) {
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final api = widget.fetchProfile != null &&
              widget.fetchUsage != null ? null : await _client();
      if (reloadProfile || _properties.isEmpty) {
        final profile = await (widget.fetchProfile != null
            ? widget.fetchProfile!(widget.device.id)
            : api!.energyProfile(widget.device.id));
        _properties = _profileFields(profile);
        if (!_properties.contains(_selected)) {
          _selected = _properties.isEmpty ? null : _properties.first;
        }
      }
      if (_selected == null) {
        if (mounted) {
          setState(() => _readings = const []);
        }
        return;
      }
      final now = DateTime.now();
      final end = _period == 'DAILY'
          ? now.subtract(const Duration(days: 1))
          : DateTime(now.year, now.month, 0);
      final start = _period == 'DAILY'
          ? end.subtract(const Duration(days: 6))
          : DateTime(end.year, end.month - 2);
      final usage = await (widget.fetchUsage != null
          ? widget.fetchUsage!(widget.device.id, _selected!, _period,
              _date(start, _period), _date(end, _period))
          : api!.energyUsage(widget.device.id, _selected!, _period,
              _date(start, _period), _date(end, _period)));
      if (mounted) {
        setState(() => _readings = _summarize(usage));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _readings = const [];
          _error = 'LG energy usage is unavailable for this appliance, '
              'token permission, or date range.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.bolt_outlined),
            const SizedBox(width: 8),
            Expanded(child: Text('Energy usage',
                style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              tooltip: 'Refresh energy readings',
              onPressed: _loading ? null : () => _refresh(),
              icon: const Icon(Icons.refresh)),
          ]),
          Text('Optional LG energy API. Readings appear only when '
              'LG supplies them for this model.',
            style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 9),
          if (_loading) const LinearProgressIndicator(),
          if (!_loading && _properties.isEmpty)
            const Text('Energy usage is not exposed for this appliance.'),
          if (_properties.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              key: const ValueKey('thinq-energy-property'),
              initialValue: _selected,
              items: [
                for (final name in _properties)
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: _loading ? null : (value) {
                setState(() => _selected = value);
                _refresh();
              },
              decoration: const InputDecoration(
                labelText: 'Reported energy metric',
                isDense: true),
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              key: const ValueKey('thinq-energy-period'),
              segments: const [
                ButtonSegment(value: 'DAILY', label: Text('Daily')),
                ButtonSegment(value: 'MONTHLY', label: Text('Monthly')),
              ],
              selected: {_period},
              onSelectionChanged: _loading ? null : (newValue) {
                setState(() => _period = newValue.first);
                _refresh();
              },
            ),
          ],
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!,
              style: Theme.of(context).textTheme.bodySmall)),
          for (final line in _readings)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(line)),
          if (!_loading && _properties.isNotEmpty &&
              _readings.isEmpty && _error == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No readings returned for this period.')),
          if (_readings.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Units depend on the LG metric. Values are '
                  'not converted or estimated by TapTether.')),
        ],
      ),
    ));
  }
}
