import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// iPhones without a Home button don't support system portrait-upside-down.
/// Rotate only the Flutter interface when Core Motion detects an inverted phone.
/// The platform status bar and home indicator remain managed by iOS.
class UpsideDownAppRotation extends StatefulWidget {
  const UpsideDownAppRotation({
    super.key,
    required this.child,
    this.orientationStream,
  });

  final Widget child;

  /// Allows deterministic tests without an iPhone motion sensor.
  final Stream<bool>? orientationStream;

  @override
  State<UpsideDownAppRotation> createState() => _UpsideDownAppRotationState();
}

class _UpsideDownAppRotationState extends State<UpsideDownAppRotation> {
  static const _channel = EventChannel('taptether/physical-orientation');
  StreamSubscription<bool>? _subscription;
  bool _inverted = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    final stream = widget.orientationStream ??
        (Platform.isIOS
            ? _channel.receiveBroadcastStream()
                .where((value) => value is bool)
                .cast<bool>()
            : const Stream<bool>.empty());
    _subscription = stream.listen((inverted) {
      if (mounted && _inverted != inverted) {
        setState(() => _inverted = inverted);
      }
    }, onError: (Object _) {
      // Keep normal orientation if motion sensing is unavailable.
    });
  }

  @override
  void didUpdateWidget(covariant UpsideDownAppRotation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orientationStream != widget.orientationStream) {
      unawaited(_subscription?.cancel());
      _subscription = null;
      _subscribe();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  EdgeInsets _rotatedInsets(EdgeInsets insets) =>
      EdgeInsets.fromLTRB(
        insets.right,
        insets.bottom,
        insets.left,
        insets.top,
      );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final content = _inverted && media != null
        ? MediaQuery(
            data: media.copyWith(
              padding: _rotatedInsets(media.padding),
              viewPadding: _rotatedInsets(media.viewPadding),
              viewInsets: _rotatedInsets(media.viewInsets),
              systemGestureInsets: _rotatedInsets(media.systemGestureInsets),
            ),
            child: widget.child,
          )
        : widget.child;

    return RotatedBox(
      key: const ValueKey('taptether-physical-orientation'),
      quarterTurns: _inverted ? 2 : 0,
      child: content,
    );
  }
}
