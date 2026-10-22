import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Experimental screen snapshot over an already authorized LG SSAP session.
/// Keeps the original touchpad gestures and occupies exactly the same space.
/// Frames stay in memory and the 15-second timer runs only while visible.
class LgSnapshotPad extends StatefulWidget {
  const LgSnapshotPad({
    super.key,
    required this.capture,
    required this.movePointer,
    required this.clickPointer,
    required this.onError,
  });

  final Future<Uint8List> Function() capture;
  final Future<void> Function(int dx, int dy) movePointer;
  final Future<void> Function() clickPointer;
  final ValueChanged<String> onError;

  @override
  State<LgSnapshotPad> createState() => _LgSnapshotPadState();
}

class _LgSnapshotPadState extends State<LgSnapshotPad>
    with WidgetsBindingObserver {
  bool _snapshot = false;
  bool _automatic = false;
  bool _busy = false;
  bool _foreground = true;
  Uint8List? _frame;
  String? _error;
  Timer? _timer;
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _timer?.cancel();
      _timer = null;
    } else if (_automatic && _snapshot) {
      _startAuto();
    }
  }

  void _startAuto() {
    _timer?.cancel();
    if (!_snapshot || !_automatic || !_foreground) {
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_busy) {
        unawaited(_refresh());
      }
    });
  }

  void _select(bool snapshot) {
    if (_snapshot == snapshot) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    setState(() {
      _snapshot = snapshot;
      _automatic = false;
      _error = null;
      if (!snapshot) _frame = null;
    });
    if (snapshot) {
      unawaited(_refresh());
    }
  }

  void _toggleAuto() {
    setState(() => _automatic = !_automatic);
    _startAuto();
  }

  Future<void> _refresh() async {
    if (!_snapshot || !_foreground || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final frame = await widget.capture();
      if (!mounted || !_snapshot) {
        return;
      }
      setState(() => _frame = frame);
    } catch (error) {
      if (!mounted || !_snapshot) {
        return;
      }
      setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
        _automatic = false;
      });
      _timer?.cancel();
      _timer = null;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _move(DragUpdateDetails details) {
    final now = DateTime.now();
    if (now.difference(_lastMove) < const Duration(milliseconds: 24)) {
      return;
    }
    _lastMove = now;
    final dx = (details.delta.dx * 2).round();
    final dy = (details.delta.dy * 2).round();
    unawaited(_execute(() => widget.movePointer(dx, dy)));
  }

  Future<void> _execute(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) widget.onError(error.toString()
          .replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _click() async {
    await _execute(widget.clickPointer);
    if (_snapshot && _foreground) {
      // Refresh after menu animations without scheduling ongoing capture.
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (mounted && _snapshot) await _refresh();
    }
  }

  Widget _content(ColorScheme scheme) {
    if (!_snapshot) {
      return const Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.touch_app_outlined, size: 32),
          SizedBox(height: 7),
          Text('Touchpad',
              style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text('Swipe to browse · Tap to click',
              style: TextStyle(fontSize: 12)),
        ],
      ));
    }
    if (_frame == null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_outlined, size: 32,
              color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(_error ?? 'Requesting TV screenshot…',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12)),
          if (_error != null)
            const Text('This TV or protected content may block capture.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11)),
          if (_busy) const SizedBox(height: 12),
          if (_busy) const CircularProgressIndicator(strokeWidth: 2),
        ]),
      ));
    }
    return Stack(fit: StackFit.expand, children: [
      Center(child: Image.memory(
        _frame!,
        key: const ValueKey('lg-snapshot-image'),
        gaplessPlayback: true,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) =>
            const Center(child: Text('TV screenshot could not be displayed.')),
      )),
      if (_busy)
        const Positioned(top: 8, right: 8,
          child: SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))),
      if (_error != null)
        Positioned(left: 8, right: 8, top: 8,
          child: Text(_error!, textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.error))),
      Positioned(left: 8, bottom: 8,
        child: DecoratedBox(
          decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: .85),
              borderRadius: BorderRadius.circular(6)),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Text('Snapshot · Swipe and tap to control',
                style: TextStyle(fontSize: 10)),
          ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Row(children: [
        ChoiceChip(
          label: const Text('Touchpad'),
          selected: !_snapshot,
          onSelected: (_) => _select(false),
        ),
        const SizedBox(width: 6),
        ChoiceChip(
          label: const Text('Snapshot'),
          selected: _snapshot,
          onSelected: (_) => _select(true),
        ),
        const Spacer(),
        if (_snapshot) ...[
          IconButton(
            tooltip: 'Refresh TV snapshot',
            onPressed: _busy ? null : () => unawaited(_refresh()),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: _automatic
                ? 'Stop automatic snapshots'
                : 'Auto refresh every 15 seconds',
            onPressed: _toggleAuto,
            icon: Icon(_automatic ? Icons.timer : Icons.timer_outlined),
          ),
        ],
      ]),
      const SizedBox(height: 5),
      Expanded(child: Semantics(
        label: _snapshot
            ? 'TV screenshot. Swipe to move pointer, tap to click.'
            : 'TV touchpad. Swipe to move pointer, tap to click.',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: _move,
          onTap: () => unawaited(_click()),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: .30),
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(23),
            ),
            child: _content(scheme),
          ),
        ),
      )),
    ]);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }
}
