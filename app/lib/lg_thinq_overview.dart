import 'package:flutter/material.dart';

import 'lg_thinq_features.dart';
import 'lg_thinq_cycle_history.dart';

/// Simple, task-focused appliance home. Raw LG resources stay on Details.
class LgThinQOverview extends StatelessWidget {
  const LgThinQOverview({
    super.key,
    required this.deviceName,
    required this.deviceType,
    required this.features,
    required this.checked,
    required this.refreshing,
    required this.onRefresh,
    required this.onCommand,
    required this.onSchedule,
  });

  final String deviceName;
  final String deviceType;
  final List<ThinQFeature> features;
  final DateTime? checked;
  final bool refreshing;
  final VoidCallback onRefresh;
  final Future<void> Function(ThinQFeature feature, Object choice) onCommand;
  final Future<void> Function(ThinQFeature feature) onSchedule;

  ThinQFeature? _field(String name) {
    for (final f in features) {
      if (f.property == name) {
        return f;
      }
    }
    return null;
  }

  String _label(String? raw) {
    if (raw == null) {
      return 'Waiting for status';
    }
    switch (raw) {
      case 'POWER_OFF': return 'Powered off';
      case 'READY': return 'Ready';
      case 'STANDBY': return 'Standby';
      case 'WASHING': return 'Washing';
      case 'RINSING': return 'Rinsing';
      case 'SPINNING': return 'Spinning';
      case 'DRYING': return 'Drying';
      case 'PAUSE':
      case 'PAUSED': return 'Paused';
      case 'END':
      case 'COMPLETE':
      case 'COMPLETED': return 'Cycle complete';
      case 'ERROR': return 'Check appliance';
      default:
        final txt = raw.replaceAll('_', ' ').toLowerCase();
        return txt.isEmpty ? 'Waiting for status'
            : '${txt[0].toUpperCase()}${txt.substring(1)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final laundry = deviceType.toUpperCase().contains('WASHER') ||
        deviceType.toUpperCase().contains('DRYER');
    final state = thinQState(features);
    final running = thinQIsRunning(state);
    final remaining = thinQMinutes(features, 'remainHour', 'remainMinute');
    final total = thinQMinutes(features, 'totalHour', 'totalMinute');
    final remote = _field('remoteControlEnabled')?.current == true;
    final counter = thinQInteger(features, 'cycleCount');
    final delay = _field('relativeHourToStart');
    final operation = _field('washerOperationMode') ??
        _field('dryerOperationMode');
    final choices = operation?.options ?? const <Object>[];
    final activeStatus = features.isNotEmpty && checked != null;

    Widget metric(String label, String value, {IconData? icon}) {
      return Expanded(child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 11),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Icon(icon, size: 19)),
            Text(value, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 3),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ));
    }

    final shade = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(running ? Icons.autorenew :
                      thinQIsFinished(state) ? Icons.check_circle_outline
                      : Icons.power_settings_new,
                      size: 25, color: shade.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_label(state),
                    style: Theme.of(context).textTheme.headlineSmall)),
                  IconButton(
                    key: const ValueKey('thinq-overview-refresh'),
                    tooltip: 'Refresh status',
                    onPressed: refreshing ? null : onRefresh,
                    icon: const Icon(Icons.refresh)),
                ]),
                const SizedBox(height: 5),
                if (running && remaining != null) ...[
                  Text('$remaining',
                    style: Theme.of(context).textTheme.displayMedium),
                  const Text('minutes remaining'),
                  const SizedBox(height: 10),
                  if (total != null && total > 0 && remaining <= total) ...[
                    LinearProgressIndicator(
                      value: ((total - remaining) / total).clamp(0.0, 1.0),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '${(100 * (total - remaining) / total).round()}% '
                      'of reported cycle duration elapsed',
                      style: Theme.of(context).textTheme.bodySmall),
                  ],
                  const SizedBox(height: 7),
                  Text('Estimated finish: ${TimeOfDay.fromDateTime(
                      DateTime.now().add(Duration(minutes: remaining)))
                      .format(context)}',
                    style: Theme.of(context).textTheme.bodyMedium),
                ] else
                  Text(activeStatus
                      ? thinQIsFinished(state)
                          ? 'Cycle finished'
                          : state == 'POWER_OFF'
                              ? 'Turn on the appliance to see live activity'
                              : 'No active cycle reported'
                      : 'Connect to LG ThinQ to see current activity',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 12),
                Text(checked == null
                    ? 'No live reading yet'
                    : 'Last synced ${TimeOfDay.fromDateTime(checked!).format(context)} '
                      '· Refreshes while this screen is open',
                    style: Theme.of(context).textTheme.bodySmall),
                if (refreshing)
                  const Padding(
                    padding: EdgeInsets.only(top: 9),
                    child: LinearProgressIndicator()),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (laundry) ...[
          Row(children: [
            metric('Total cycle', total == null ? '—' : '$total min',
                icon: Icons.timelapse_outlined),
            const SizedBox(width: 9),
            metric('Cycle count', counter == null ? '—' : '$counter',
                icon: Icons.repeat_outlined),
            const SizedBox(width: 9),
            metric('Remote start', remote ? 'Ready' : 'Not ready',
                icon: Icons.wifi_tethering),
          ]),
          const SizedBox(height: 14),
          Text('Controls',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 7),
          if (operation != null && choices.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (choices.contains('START'))
                FilledButton.icon(
                  key: const ValueKey('thinq-start'),
                  onPressed: remote && !running && operation.permits('START')
                      ? () => onCommand(operation, 'START') : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start cycle')),
              if (choices.contains('STOP'))
                OutlinedButton.icon(
                  key: const ValueKey('thinq-stop'),
                  onPressed: running && operation.permits('STOP')
                      ? () => onCommand(operation, 'STOP') : null,
                  icon: const Icon(Icons.stop_outlined),
                  label: const Text('Stop')),
              if (choices.contains('POWER_OFF'))
                OutlinedButton.icon(
                  key: const ValueKey('thinq-power-off'),
                  onPressed: state != 'POWER_OFF' &&
                          operation.permits('POWER_OFF')
                      ? () => onCommand(operation, 'POWER_OFF') : null,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Power off')),
            ])
          else
            const Text('LG has not reported remote operation controls '
                'for this model.'),
          if (!remote) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Remote Start is off. Load the washer/dryer, close the '
              'door or lid, and enable Remote Start on the appliance. '
              'Tap Refresh to check again.',
              style: Theme.of(context).textTheme.bodySmall),
          ),
          if (delay != null) ...[
            const SizedBox(height: 14),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                key: const ValueKey('thinq-delay-start'),
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('Delayed start'),
                subtitle: Text(delay.current == null
                    ? 'No delay reported'
                    : '${delay.current} hours · LG setting'),
                trailing: delay.actionable
                    ? const Icon(Icons.chevron_right) : null,
                onTap: delay.actionable
                    ? () => onSchedule(delay) : null,
              ),
            ),
            const SizedBox(height: 6),
            Text('Delay sets the washer’s relative start timer; it does '
                'not create an independent TapTether automation.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
        ] else ...[
          const SizedBox(height: 4),
          Text('Refrigerator details',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text('Temperatures, doors, filters and adjustable settings '
              'are available under Features when reported by this model.'),
        ],
        if (laundry)
          Text('Activity is available while this screen is open. '
              'Observed cycles are saved in the History tab; '
              'older LG-app history is not imported.',
              style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
