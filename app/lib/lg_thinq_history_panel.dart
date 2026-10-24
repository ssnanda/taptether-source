import 'package:flutter/material.dart';

import 'lg_thinq_cycle_history.dart';

/// History is built from TapTether's own successful ThinQ observations,
/// not from LG's historical timeline. Never invent skipped cycles.
class LgThinQHistoryPanel extends StatelessWidget {
  const LgThinQHistoryPanel({
    super.key, required this.history, this.reportedCycleCount,
    required this.onClear, this.energy,
  });

  final List<ThinQCycleEntry> history;
  final int? reportedCycleCount;
  final VoidCallback onClear;
  final Widget? energy;

  @override
  Widget build(BuildContext context) {
    String time(DateTime date) =>
        MaterialLocalizations.of(context).formatMediumDate(date) +
        ' · ' + TimeOfDay.fromDateTime(date).format(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(margin: EdgeInsets.zero, child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Cycle history',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text('${history.length} observed sessions'
                  '${reportedCycleCount == null ? "" :
                      " · $reportedCycleCount total cycles reported by LG"}'),
              const SizedBox(height: 7),
              Text('TapTether records cycles only when it receives '
                  'their live state. Previously completed cycles cannot '
                  'be reconstructed from the cumulative counter.',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        )),
        const SizedBox(height: 12),
        if (history.isEmpty)
          Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              const Icon(Icons.history, size: 32),
              const SizedBox(height: 10),
              const Text('No cycles recorded yet'),
              const SizedBox(height: 5),
              Text('Open this appliance while it runs. TapTether '
                  'will record the states it observes and keep a local '
                  'history on this phone.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
            ]),
          ))
        else ...[
          for (final entry in history)
            Card(child: ListTile(
              leading: Icon(entry.active
                  ? Icons.sync_outlined :
                  entry.outcome == 'finished'
                      ? Icons.check_circle_outline
                      : Icons.help_outline),
              title: Text(entry.active
                  ? 'In progress · observed'
                  : entry.outcome == 'finished'
                      ? 'Cycle completed · observed'
                      : 'Cycle stopped / outcome unknown'),
              subtitle: Text('First observed: ${time(entry.startedAt)}'
                  '\nLast observed: ${time(entry.lastSeenAt)}'
                  '\nLast state: ${entry.lastState.replaceAll("_", " ")}'
                  '${entry.initialTotalMinutes == null
                      ? "" : "\\nReported cycle: ${entry.initialTotalMinutes} min"}'
                  '\n${entry.samples} status samples'),
              isThreeLine: true,
            )),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('thinq-clear-history'),
              onPressed: onClear,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Clear local history'),
            ),
          ),
        ],
        if (energy != null) ...[
          const SizedBox(height: 12),
          energy!,
        ],
      ],
    );
  }
}
