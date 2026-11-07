import 'dart:ui' show Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/tcl_google_tv_protocol/key_codes.dart';
import 'package:taptether/tcl_google_tv_touchpad.dart';

void main() {
  test('slow swipe triggers one direction only past threshold', () {
    final pad = TclGoogleTvTouchpadInterpreter();
    expect(pad.feed(const Offset(30, 2)), isEmpty);
    expect(pad.feed(const Offset(33, 2)), isEmpty);
    expect(pad.feed(const Offset(3, 0)), [KeyCode.dpadRight]);
    pad.reset();
    expect(pad.feed(const Offset(0, -67)), [KeyCode.dpadUp]);
  });

  test('long gestures repeat D-pad steps without flooding', () {
    final pad = TclGoogleTvTouchpadInterpreter();
    expect(pad.feed(const Offset(-140, 1)), [
      KeyCode.dpadLeft, KeyCode.dpadLeft,
    ]);
    expect(pad.feed(const Offset(-800, 0)).length, 4);
    pad.reset();
    expect(pad.feed(const Offset(0, 70)), [KeyCode.dpadDown]);
  });

  test('diagonal swipes prioritize the dominant direction', () {
    final pad = TclGoogleTvTouchpadInterpreter();
    expect(pad.feed(const Offset(30, -100)), [KeyCode.dpadUp]);
    pad.reset();
    expect(pad.feed(const Offset(115, 20)), [KeyCode.dpadRight]);
  });

  test('zero movement, invalid movements and reset send no keys', () {
    final pad = TclGoogleTvTouchpadInterpreter();
    expect(pad.feed(Offset.zero), isEmpty);
    expect(pad.feed(const Offset(60, 0)), isEmpty);
    pad.reset();
    expect(pad.feed(const Offset(6, 0)), isEmpty);
    expect(pad.feed(const Offset(double.nan, 0)), isEmpty);
    expect(pad.feed(const Offset(0, double.infinity)), isEmpty);
  });
}
