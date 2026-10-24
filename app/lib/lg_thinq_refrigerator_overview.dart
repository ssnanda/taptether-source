import 'package:flutter/material.dart';

import 'lg_thinq_features.dart';

/// Refrigerator-specific home screen. Temperatures are setpoints, not
/// measured compartment temperatures; all commands use LG profile metadata.
class LgThinQRefrigeratorOverview extends StatelessWidget {
  const LgThinQRefrigeratorOverview({
    super.key,
    required this.features,
    required this.checked,
    required this.refreshing,
    required this.onRefresh,
    required this.onCommand,
    required this.onEdit,
  });

  final List<ThinQFeature> features;
  final DateTime? checked;
  final bool refreshing;
  final VoidCallback onRefresh;
  final Future<void> Function(ThinQFeature feature, Object choice) onCommand;
  final Future<void> Function(ThinQFeature feature) onEdit;

  ThinQFeature? _field(String property, {String? resource, String? location}) {
    for (final feature in features) {
      if (feature.property == property &&
          (resource == null || feature.resource == resource) &&
          (location == null || feature.location == location)) {
        return feature;
      }
    }
    return null;
  }

  ThinQFeature? _setpoint(String compartment) =>
      _field('targetTemperatureF',
          resource: 'temperatureInUnits', location: compartment) ??
      _field('targetTemperatureC',
          resource: 'temperatureInUnits', location: compartment);

  String _setpointText(ThinQFeature? feature) {
    if (feature == null || feature.current == null) return '—';
    final unit = feature.property.endsWith('F') ? '°F' : '°C';
    return '${feature.currentText}$unit';
  }

  String _doorText(Object? value) {
    final state = value?.toString().toUpperCase();
    if (state == 'CLOSE' || state == 'CLOSED') return 'Closed';
    if (state == 'OPEN' || state == 'OPENED') return 'Open';
    return value == null ? 'Not reported' : value.toString();
  }

  String _booleanText(Object? value) {
    if (value == true) return 'Enabled';
    if (value == false) return 'Disabled';
    return value?.toString().replaceAll('_', ' ') ?? 'Not reported';
  }

  bool _needsReplacement(ThinQFeature? feature) =>
      feature?.current?.toString().toUpperCase() == 'REPLACE';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fridge = _setpoint('FRIDGE');
    final freezer = _setpoint('FREEZER');
    final door = _field('doorState',
        resource: 'doorStatus', location: 'MAIN');
    final express = _field('expressMode', resource: 'refrigeration');
    final expressName = _field('expressModeName',
        resource: 'refrigeration');
    final freshFilter = _field('freshAirFilter',
        resource: 'refrigeration');
    final waterFilter = _field('waterFilterState',
        resource: 'waterFilterInfo');
    final usedTime = _field('usedTime', resource: 'waterFilterInfo');
    final powerSave = _field('powerSaveEnabled', resource: 'powerSave');
    final sabbath = _field('sabbathMode', resource: 'sabbath');

    Widget setpointCard(String label, ThinQFeature? feature) {
      return Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelLarge),
                const SizedBox(height: 7),
                Text(_setpointText(feature),
                    maxLines: 1,
                    style: theme.textTheme.headlineMedium),
                const SizedBox(height: 4),
                Text('Target temperature',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                if (feature != null && feature.actionable)
                  OutlinedButton.icon(
                    key: ValueKey('thinq-setpoint-${label.toLowerCase()}'),
                    onPressed: refreshing ? null : () => onEdit(feature),
                    icon: const Icon(Icons.tune, size: 17),
                    label: const Text('Adjust'),
                  )
                else
                  Text('Read-only',
                      style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
    }

    Widget informationRow(IconData icon, String title, String status,
        {bool warning = false, Widget? action, String? detail}) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 23,
                  color: warning ? theme.colorScheme.error : null),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  Text(status,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: warning ? theme.colorScheme.error : null)),
                  if (detail != null)
                    Text(detail, style: theme.textTheme.bodySmall),
                ],
              )),
              if (action != null) ...[
                const SizedBox(width: 8),
                action,
              ],
            ],
          ),
        ),
      );
    }

    final doorStatus = _doorText(door?.current);
    final freshReplace = _needsReplacement(freshFilter);
    final waterReplace = _needsReplacement(waterFilter);
    final canToggleExpress = express != null && express.actionable &&
        express.current is bool;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Icon(Icons.kitchen_outlined, size: 24),
          const SizedBox(width: 8),
          Expanded(child: Text('Refrigerator',
              style: theme.textTheme.titleLarge)),
          IconButton(
            key: const ValueKey('thinq-fridge-refresh'),
            tooltip: 'Refresh refrigerator status',
            onPressed: refreshing ? null : onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          setpointCard('Fridge', fridge),
          const SizedBox(width: 8),
          setpointCard('Freezer', freezer),
        ]),
        const SizedBox(height: 8),
        Text('These are LG target setpoints, not measured internal '
            'temperatures. Tap Adjust to choose a value supported '
            'by this model.', style: theme.textTheme.bodySmall),
        const SizedBox(height: 14),
        informationRow(
          doorStatus == 'Open' ? Icons.door_front_door_outlined :
              Icons.door_sliding_outlined,
          'Main door', doorStatus,
          warning: doorStatus == 'Open',
        ),
        if (express != null)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: SwitchListTile.adaptive(
              key: const ValueKey('thinq-express-freeze'),
              title: const Text('Express Freeze'),
              subtitle: Text(
                '${_booleanText(express.current)}'
                '${expressName?.current == null ? "" :
                    " · ${expressName!.currentText}"}'),
              value: express.current == true,
              onChanged: canToggleExpress && !refreshing
                  ? (enabled) => onCommand(express, enabled)
                  : null,
            ),
          ),
        informationRow(
          Icons.air_outlined,
          'Fresh air filter',
          freshFilter?.currentText ?? 'Not reported',
          warning: freshReplace,
          detail: freshReplace
              ? 'LG reports replacement needed; Auto/Power are modes, '
                'not filter reset commands.'
              : null,
          action: freshFilter != null && freshFilter.actionable
              ? TextButton(
                  key: const ValueKey('thinq-fresh-air-mode'),
                  onPressed: refreshing ? null : () => onEdit(freshFilter),
                  child: const Text('Mode'))
              : null,
        ),
        informationRow(
          Icons.water_drop_outlined,
          'Water filter',
          waterFilter?.currentText ?? 'Not reported',
          warning: waterReplace,
          detail: usedTime?.current == null
              ? null : 'Used time: ${usedTime!.currentText} '
                  '(unit not reported)',
        ),
        informationRow(
          Icons.energy_savings_leaf_outlined,
          'Power save', _booleanText(powerSave?.current),
        ),
        informationRow(
          Icons.nightlight_outlined,
          'Sabbath mode', _booleanText(sabbath?.current),
        ),
        const SizedBox(height: 6),
        Text(
          checked == null
              ? 'No fresh status reading yet'
              : 'Last synced ${TimeOfDay.fromDateTime(checked!).format(context)} '
                  '· Uses LG ThinQ cloud',
          style: theme.textTheme.bodySmall,
        ),
        if (refreshing)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}
