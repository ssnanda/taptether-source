import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/phone_sound_meter.dart';

void main() {
  test('ambient level is a bounded estimate with optional calibration', () {
    expect(approximateAmbientDb(-80), 20);
    expect(approximateAmbientDb(-35), 65);
    expect(approximateAmbientDb(-35, correction: 5), 70);
    expect(approximateAmbientDb(40), 120);
    expect(approximateAmbientDb(-150), 0);
  });

  testWidgets('sound meter is opt-in, labeled approximate, not TV-only',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PhoneSoundMeterSheet())));
    expect(find.text('Sound level · Phone mic'), findsOneWidget);
    expect(find.text('— dB'), findsOneWidget);
    expect(find.textContaining('not a direct measurement'), findsOneWidget);
    expect(find.byKey(const ValueKey('lg-phone-db-start-stop')),
        findsOneWidget);
    expect(find.text('Start measuring'), findsOneWidget);
    expect(find.byKey(const ValueKey('lg-db-calibration')), findsOneWidget);
    // Opening the sheet must not start native microphone capture.
  });
}
