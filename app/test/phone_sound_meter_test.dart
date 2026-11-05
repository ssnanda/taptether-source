import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/phone_sound_meter.dart';

void main() {
  test('ambient level is a bounded estimate', () {
    expect(approximateAmbientDb(-80), 20);
    expect(approximateAmbientDb(-35), 65);
    expect(approximateAmbientDb(-35, correction: 5), 70);
    expect(approximateAmbientDb(40), 120);
    expect(approximateAmbientDb(-150), 0);
  });

  testWidgets('inline meter starts automatically, updates dB and stops',
      (tester) async {
    const channel = MethodChannel('taptether/sound-meter');
    final commands = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel, (call) async {
        commands.add(call.method);
        return call.method == 'start' ? true : null;
      });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PhoneSoundLevelInline())));
    await tester.pump();
    expect(commands, contains('start'));
    expect(find.text('— dB'), findsOneWidget);
    expect(find.text('Start measuring'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);

    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'taptether/sound-meter',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('level', <String, Object>{
          'dbfs': -35, 'microphone': 'Bottom microphone',
        })),
      (_) {},
    );
    await tester.pump();
    expect(find.text('≈ 65 dB'), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('Bottom mic near USB-C'));

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump();
    expect(commands, contains('stop'));
  });

  testWidgets('disabled meter waits for the screen to enable it',
      (tester) async {
    const channel = MethodChannel('taptether/sound-meter');
    final commands = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel, (call) async {
        commands.add(call.method);
        return call.method == 'start' ? true : null;
      });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PhoneSoundLevelInline(enabled: false))));
    await tester.pump();
    expect(commands, isNot(contains('start')));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PhoneSoundLevelInline())));
    await tester.pump();
    expect(commands, contains('start'));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PhoneSoundLevelInline(enabled: false))));
    await tester.pump();
    expect(commands, contains('stop'));
  });
}
