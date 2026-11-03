import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'tv_quick_controls.dart';

/// Configures native LG Lock Screen and Control Center actions.
/// Apple controls the Live Activity's outer width, so Wide maximizes the
/// internal button space without exceeding the 160pt height budget.
class TvControlsSettingsScreen extends StatefulWidget {
  const TvControlsSettingsScreen({super.key});

  @override
  State<TvControlsSettingsScreen> createState() =>
      _TvControlsSettingsScreenState();
}

class _TvControlsSettingsScreenState extends State<TvControlsSettingsScreen> {
  String _layout = 'compact';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final layout = await TvQuickControls.instance.getLockScreenLayout();
      if (!mounted) return;
      setState(() {
        _layout = layout;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load the Lock Screen layout.';
        });
      }
    }
  }

  Future<void> _save(String value) async {
    if (_saving || value == _layout) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await TvQuickControls.instance.setLockScreenLayout(value);
      if (mounted) setState(() => _layout = value);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save the Lock Screen layout.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('TV Quick Controls')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.lock_clock_outlined,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 10),
                      Text('Lock Screen layout',
                          style: theme.textTheme.titleMedium),
                    ]),
                    const SizedBox(height: 12),
                    if (_loading) const LinearProgressIndicator(),
                    if (!_loading)
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<String>(
                          key: const ValueKey('tv-lock-layout-picker'),
                          segments: const [
                            ButtonSegment(
                              value: 'compact',
                              icon: Icon(Icons.view_compact_outlined),
                              label: Text('Compact')),
                            ButtonSegment(
                              value: 'wide',
                              icon: Icon(Icons.view_agenda_outlined),
                              label: Text('Wide')),
                          ],
                          selected: {_layout},
                          onSelectionChanged: _saving
                              ? null : (values) => _save(values.first),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(_layout == 'wide'
                        ? 'Wide: larger buttons and less empty space. All ten '
                          'TV controls remain available.'
                        : 'Compact: smaller buttons and more space around '
                          'the controls. All ten actions remain available.'),
                    const SizedBox(height: 8),
                    Text(
                      'iOS sets the outer panel width. This preference changes '
                      'button sizing and spacing inside it.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.tune_rounded,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 10),
                      Text('Control Center',
                          style: theme.textTheme.titleMedium),
                    ]),
                    const SizedBox(height: 10),
                    const Text('Add TapTether controls to the panel that '
                        'opens when you swipe down from the top-right.'),
                    const SizedBox(height: 12),
                    const Text('1. Swipe down from the top-right corner.'),
                    const SizedBox(height: 6),
                    const Text('2. Touch and hold an empty area, then '
                        'tap Add a Control.'),
                    const SizedBox(height: 6),
                    const Text('3. Search for TapTether and add the '
                        'TV actions you want. Arrange or resize them there.'),
                    const SizedBox(height: 16),
                    Text('Available TV controls',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(spacing: 7, runSpacing: 7, children: [
                      for (final title in const [
                        'Power', 'Volume −', 'Volume +', 'Mute',
                        'Home', 'Back', 'OK', 'Netflix', 'YouTube',
                        'Prime Video', 'Apple TV', 'Apps',
                      ])
                        Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(title),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    Text(
                      'Buttons control your most recently selected, paired '
                      'LG TV over local Wi-Fi without opening TapTether. '
                      'Choose that TV once in the app. '
                      'Control Center additions are managed by iOS.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            if (!Platform.isIOS) const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Control Center buttons require iOS 18 or later.'),
            ),
          ],
        ),
      ),
    );
  }
}
