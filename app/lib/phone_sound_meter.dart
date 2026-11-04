import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A rough estimate of ambient sound at the phone, not calibrated TV SPL.
double approximateAmbientDb(double dbfs, {double correction = 0}) =>
    (dbfs + 100 + correction).clamp(0.0, 120.0).toDouble();

/// Measures while the TV remote is visible; never saves or uploads audio.
class PhoneSoundLevelInline extends StatefulWidget {
  const PhoneSoundLevelInline({super.key, this.enabled = true});

  /// Suspend capture when voice search needs the microphone.
  final bool enabled;

  @override
  State<PhoneSoundLevelInline> createState() => _PhoneSoundLevelInlineState();
}

class _PhoneSoundLevelInlineState extends State<PhoneSoundLevelInline>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('taptether/sound-meter');
  bool _foreground = true;
  bool _starting = false;
  bool _running = false;
  bool _unavailable = false;
  double? _dbfs;

  bool get _shouldRun => mounted && _foreground && widget.enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'level' || !mounted || !_running || !_shouldRun) {
        return;
      }
      final args = call.arguments;
      if (args is Map && args['dbfs'] is num) {
        setState(() => _dbfs = (args['dbfs'] as num).toDouble());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    if (!_shouldRun || _running || _starting) return;
    _starting = true;
    try {
      final allowed = await _channel.invokeMethod<bool>('start') ?? false;
      if (!_shouldRun) {
        if (allowed) await _stop();
        return;
      }
      setState(() {
        _running = allowed;
        _unavailable = !allowed;
        _dbfs = null;
      });
    } on PlatformException {
      if (_shouldRun) setState(() => _unavailable = true);
    } on MissingPluginException {
      if (_shouldRun) setState(() => _unavailable = true);
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop() async {
    if (mounted) {
      setState(() {
        _running = false;
        _dbfs = null;
      });
    }
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // iOS may have already stopped microphone capture.
    }
  }

  @override
  void didUpdateWidget(covariant PhoneSoundLevelInline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled == oldWidget.enabled) return;
    if (widget.enabled) {
      unawaited(_start());
    } else {
      unawaited(_stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      unawaited(_start());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      unawaited(_stop());
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
    final level = _dbfs == null ? null : approximateAmbientDb(_dbfs!);
    final display = level == null
        ? (_unavailable ? 'Mic off' : '— dB')
        : '≈ ${level.round()} dB';
    final scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: _unavailable
          ? 'Enable the TapTether microphone in iPhone Settings'
          : 'Approximate room sound at the phone microphone',
      child: Semantics(
        label: level == null
            ? 'Phone sound level unavailable'
            : 'Approximate sound at phone: ${level.round()} decibels',
        child: InkWell(
          onTap: _unavailable ? () => unawaited(_start()) : null,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.multitrack_audio_outlined, size: 17,
                  color: scheme.primary),
              const SizedBox(width: 4),
              Text(display, key: const ValueKey('lg-phone-db-value'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.primary, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}
