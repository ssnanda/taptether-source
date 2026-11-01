import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A rough on-phone ambient sound estimate, NOT a calibrated dB SPL reading.
/// Phone microphone gain and placement vary, so we avoid claiming the TV alone
/// produced the sound or that this value is suitable for safety decisions.
double approximateAmbientDb(double dbfs, {double correction = 0}) =>
    (dbfs + 100 + correction).clamp(0.0, 120.0).toDouble();

class PhoneSoundMeterSheet extends StatefulWidget {
  const PhoneSoundMeterSheet({super.key});

  @override
  State<PhoneSoundMeterSheet> createState() => _PhoneSoundMeterSheetState();
}

class _PhoneSoundMeterSheetState extends State<PhoneSoundMeterSheet>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('taptether/sound-meter');
  bool _starting = false;
  bool _running = false;
  double? _dbfs;
  String? _error;
  double _calibration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'level' || !mounted || !_running) return;
      final args = call.arguments;
      if (args is Map && args['dbfs'] is num) {
        setState(() => _dbfs = (args['dbfs'] as num).toDouble());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_stop());
    }
  }

  Future<void> _start() async {
    if (_starting || _running) return;
    setState(() { _starting = true; _error = null; });
    try {
      final allowed = await _channel.invokeMethod<bool>('start') ?? false;
      if (!mounted) {
        if (allowed) await _channel.invokeMethod<void>('stop');
        return;
      }
      setState(() {
        _running = allowed;
        if (!allowed) {
          _error = 'Microphone access is off. Allow TapTether microphone '
              'access in iPhone Settings to measure room sound.';
        }
      });
    } on PlatformException catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Unable to start the phone microphone. Try again.');
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() =>
            _error = 'The sound meter requires the iPhone version of TapTether.');
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    if (mounted) setState(() { _running = false; _dbfs = null; });
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Recording may already be stopped by iOS.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    unawaited(_channel.invokeMethod<void>('stop').catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final level = _dbfs == null
        ? null : approximateAmbientDb(_dbfs!, correction: _calibration);
    return SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.multitrack_audio_outlined),
            const SizedBox(width: 8),
            Expanded(child: Text('Sound level · Phone mic',
                style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: 'Close sound meter',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 12),
          Center(child: Text(level == null
              ? '— dB' : '≈ ${level.round()} dB',
              key: const ValueKey('lg-phone-db-value'),
              style: Theme.of(context).textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: scheme.primary,
              ))),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: level == null ? 0 : (level / 110).clamp(0, 1).toDouble(),
            minHeight: 12, borderRadius: BorderRadius.circular(8)),
          const SizedBox(height: 10),
          const Text('Approximate sound at the PHONE, including voices, '
              'traffic and other room noise. It is not a direct measurement '
              'of the TV or a calibrated sound-level meter.'),
          const SizedBox(height: 12),
          Text('Calibration adjustment: '
              '${_calibration >= 0 ? '+' : ''}${_calibration.round()} dB',
              style: Theme.of(context).textTheme.labelMedium),
          Slider(
            key: const ValueKey('lg-db-calibration'),
            value: _calibration, min: -20, max: 20, divisions: 40,
            label: '${_calibration.round()} dB',
            onChanged: (value) => setState(() => _calibration = value)),
          const Text('Optional: compare against a calibrated sound meter '
              'at the same location and adjust the offset. Changes are '
              'temporary and audio is never stored or uploaded.'),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!,
              style: TextStyle(color: scheme.error))),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const ValueKey('lg-phone-db-start-stop'),
            onPressed: _starting ? null : (_running ? _stop : _start),
            icon: Icon(_running ? Icons.stop_circle_outlined
                : Icons.mic_none),
            label: Text(_starting ? 'Starting microphone…'
                : _running ? 'Stop measuring' : 'Start measuring'),
          ),
        ],
      ),
    ));
  }
}
