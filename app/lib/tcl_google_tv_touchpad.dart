import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'tcl_google_tv_protocol/key_codes.dart';

/// Converts finger travel into discrete Google TV D-pad commands.
/// Remote Service v2 accepts key injections, not LG webOS-style pointer
/// coordinates. Each 64px of dominant-axis movement sends one key.
class TclGoogleTvTouchpadInterpreter {
  TclGoogleTvTouchpadInterpreter({this.stepDistance = 64});

  final double stepDistance;
  Offset _pending = Offset.zero;

  void reset() => _pending = Offset.zero;

  List<int> feed(Offset movement) {
    if (!movement.dx.isFinite || !movement.dy.isFinite ||
        stepDistance <= 0) {
      return const [];
    }
    _pending += movement;
    final commands = <int>[];
    // Bound the number of keys from a single UI event, even if drag event
    // delivery stalls and then reports a large distance.
    for (var i = 0; i < 4; i++) {
      final dx = _pending.dx;
      final dy = _pending.dy;
      if (math.max(dx.abs(), dy.abs()) < stepDistance) {
        break;
      }
      if (dx.abs() >= dy.abs()) {
        commands.add(dx > 0 ? KeyCode.dpadRight : KeyCode.dpadLeft);
        _pending = Offset(
          dx - (dx > 0 ? stepDistance : -stepDistance),
          dy * 0.25,
        );
      } else {
        commands.add(dy > 0 ? KeyCode.dpadDown : KeyCode.dpadUp);
        _pending = Offset(
          dx * 0.25,
          dy - (dy > 0 ? stepDistance : -stepDistance),
        );
      }
    }
    return commands;
  }
}
