import 'package:flutter/material.dart';

import 'lg_thinq_features.dart';

/// Compact refrigerator home. LG reports target setpoints, not measured temps.
/// One-step changes are allowed only by this model's declared numeric range.
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
  final Future<void> Function(ThinQFeature, Object) onCommand;
  final Future<void> Function(ThinQFeature) onEdit;

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

  String _value(ThinQFeature? feature) {
    if (feature?.current == null) return '—';
    return '${feature!.currentText}°${feature.property.endsWith("F") ? "F" : "C"}';
  }

  String _door(Object? raw) {
    switch (raw?.toString().toUpperCase()) {
      case 'CLOSE':
      case 'CLOSED':
        return 'Closed';
      case 'OPEN':
      case 'OPENED':
        return 'Open';
      default:
        return 'Not reported';
    }
  }

  String _status(Object? value) {
    if (value == true) return 'On';
    if (value == false) return 'Off';
    return value?.toString().replaceAll('_', ' ') ?? 'Not reported';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final fridge = _setpoint('FRIDGE');
    final freezer = _setpoint('FREEZER');
    final door = _field('doorState', resource: 'doorStatus', location: 'MAIN');
    final express = _field('expressMode', resource: 'refrigeration');
    final expressName = _field('expressModeName', resource: 'refrigeration');
    final fresh = _field('freshAirFilter', resource: 'refrigeration');
    final water = _field('waterFilterState', resource: 'waterFilterInfo');
    final waterUsed = _field('usedTime', resource: 'waterFilterInfo');
    final powerSave = _field('powerSaveEnabled', resource: 'powerSave');
    final sabbath = _field('sabbathMode', resource: 'sabbath');

    Widget temperatureCard(String label, IconData icon, ThinQFeature? feature) {
      final current = feature?.current;
      final step = feature?.step ?? 1;
      final number = current is num ? current : null;
      final canEdit = feature != null && feature.actionable && number != null;
      final down = number == null ? null : number - step;
      final up = number == null ? null : number + step;
      final unit = feature?.property.endsWith('F') == true ? '°F' : '°C';
      return Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          color: colors.primaryContainer.withValues(alpha: 0.25),
          elevation: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                key: ValueKey('thinq-setpoint-${label.toLowerCase()}'),
                onTap: canEdit && !refreshing ? () => onEdit(feature) : null,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(13, 13, 10, 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(icon, size: 20, color: colors.primary),
                        const SizedBox(width: 6),
                        Expanded(child: Text(label,
                            style: theme.textTheme.titleSmall)),
                        if (canEdit)
                          const Icon(Icons.chevron_right, size: 19),
                      ]),
                      const SizedBox(height: 9),
                      Text(_value(feature),
                          style: theme.textTheme.headlineMedium?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 1),
                      Text('Target · ${feature?.minimum ?? "—"}'
                          '–${feature?.maximum ?? "—"}$unit',
                          maxLines: 1,
                          style: theme.textTheme.labelSmall),
                    ],
                  ),
                ),
              ),
              if (canEdit) Padding(
                padding: const EdgeInsets.fromLTRB(7, 3, 7, 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton.filledTonal(
                      key: ValueKey('thinq-${label.toLowerCase()}-minus'),
                      tooltip: 'Decrease $label target',
                      visualDensity: VisualDensity.compact,
                      onPressed: !refreshing && feature.permits(down!)
                          ? () => onCommand(feature, down) : null,
                      icon: const Icon(Icons.remove, size: 19),
                    ),
                    Text('Adjust', style: theme.textTheme.labelSmall),
                    IconButton.filledTonal(
                      key: ValueKey('thinq-${label.toLowerCase()}-plus'),
                      tooltip: 'Increase $label target',
                      visualDensity: VisualDensity.compact,
                      onPressed: !refreshing && feature.permits(up!)
                          ? () => onCommand(feature, up) : null,
                      icon: const Icon(Icons.add, size: 19),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget statusRow(IconData icon, String label, String value,
        {bool attention = false, Widget? trailing, String? note}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(icon, size: 21,
              color: attention ? colors.error : colors.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.titleSmall),
              if (note != null)
                Text(note, style: theme.textTheme.bodySmall),
            ],
          )),
          const SizedBox(width: 7),
          if (trailing != null) trailing else
            Flexible(child: Text(value, textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: attention ? colors.error : colors.onSurfaceVariant,
                fontWeight: attention ? FontWeight.w600 : null))),
        ]),
      );
    }

    final doorState = _door(door?.current);
    final freshWarning = fresh?.current?.toString() == 'REPLACE';
    final waterWarning = water?.current?.toString() == 'REPLACE';
    final expressReady = express != null && express.actionable &&
        express.current is bool;
    final modes = fresh?.options
        .whereType<String>()
        .where((v) => v == 'AUTO' || v == 'POWER')
        .toList() ?? <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Text('Temperatures', style: theme.textTheme.titleMedium),
          const Spacer(),
          IconButton(
            key: const ValueKey('thinq-fridge-refresh'),
            tooltip: 'Refresh from LG',
            onPressed: refreshing ? null : onRefresh,
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ]),
        Row(children: [
          temperatureCard('Fridge', Icons.ac_unit, fridge),
          const SizedBox(width: 8),
          temperatureCard('Freezer', Icons.severe_cold_outlined, freezer),
        ]),
        const SizedBox(height: 5),
        Text('Set temperatures · not internal sensor readings',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            child: Column(children: [
              statusRow(Icons.door_front_door_outlined, 'Main door',
                  doorState, attention: doorState == 'Open'),
              if (express != null) ...[
                const Divider(height: 12),
                statusRow(Icons.ac_unit, 'Express Freeze',
                    _status(express.current),
                    note: expressName?.current?.toString() == 'FREEZER'
                        ? 'Ice Plus · Freezer' : 'Rapid cooling',
                    trailing: Switch.adaptive(
                      key: const ValueKey('thinq-express-freeze'),
                      value: express.current == true,
                      onChanged: expressReady && !refreshing
                          ? (enabled) => onCommand(express, enabled)
                          : null,
                    )),
              ],
              if (fresh != null) ...[
                const Divider(height: 12),
                statusRow(Icons.air_outlined, 'Fresh air filter',
                    freshWarning ? 'Replace' : _status(fresh.current),
                    attention: freshWarning,
                    note: freshWarning ? 'Replacement indicated by LG' : null,
                    trailing: modes.isEmpty ? null : PopupMenuButton<String>(
                      key: const ValueKey('thinq-fresh-air-mode'),
                      tooltip: 'Choose air-filter operating mode',
                      enabled: !refreshing,
                      onSelected: (v) => onCommand(fresh, v),
                      itemBuilder: (context) => [
                        for (final mode in modes)
                          PopupMenuItem(value: mode,
                              child: Text(mode == 'AUTO' ? 'Auto mode'
                                  : 'Power mode')),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text('Mode'),
                          Icon(Icons.expand_more, size: 19),
                        ]),
                      ),
                    )),
              ],
              if (water != null) ...[
                const Divider(height: 12),
                statusRow(Icons.water_drop_outlined, 'Water filter',
                    waterWarning ? 'Replace' : _status(water.current),
                    attention: waterWarning,
                    note: waterUsed?.current == null ? null :
                        'Used time: ${waterUsed!.currentText} (unit not reported)'),
              ],
              if (powerSave != null) ...[
                const Divider(height: 12),
                statusRow(Icons.energy_savings_leaf_outlined,
                    'Power save', _status(powerSave.current)),
              ],
              if (sabbath != null) ...[
                const Divider(height: 12),
                statusRow(Icons.nightlight_outlined,
                    'Sabbath mode', _status(sabbath.current)),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 9),
        Text(checked == null
            ? 'Waiting for LG ThinQ status'
            : 'LG ThinQ cloud · Updated ${TimeOfDay.fromDateTime(checked!).format(context)}',
            style: theme.textTheme.bodySmall),
        if (refreshing) const Padding(
          padding: EdgeInsets.only(top: 5),
          child: LinearProgressIndicator(minHeight: 2),
        ),
      ],
    );
  }
}
