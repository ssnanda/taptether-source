import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_compact_remote.dart';
import 'package:taptether/lg_webos_client.dart';

class FakeLgRemote extends LgWebOsClient {
  FakeLgRemote() : super(const LgTvDevice(
    host: '192.168.68.62', name: 'Family Room TV', clientKey: 'saved'));

  int clicks = 0;
  @override
  bool get connected => true;
  @override
  Future<List<({String id, String title})>> apps() async => [
    (id: 'youtube.leanback.v4', title: 'YouTube'),
    (id: 'netflix', title: 'Netflix'),
  ];
  @override
  Future<String?> foregroundApp() async => 'netflix';
  @override
  Future<int?> volumeLevel() async => 25;
  @override
  Future<void> pointerClick() async { clicks++; }
  @override
  Future<void> pointerMove(int dx, int dy) async {}
  @override
  Future<void> button(String name) async {}
  @override
  Future<void> launchApp(String appId) async {}
}

void main() {
  testWidgets('compact remote fits viewport without scrolling or number pad',
      (tester) async {
    final fake = FakeLgRemote();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 390, height: 600,
        child: LgCompactRemote(
          client: fake, device: fake.device, onError: (_) {}),
      )),
    ));
    await tester.pump();
    expect(find.byType(ListView), findsNothing);
    expect(find.text('Touchpad'), findsOneWidget);
    expect(find.text('Arrows · OK'), findsOneWidget);
    expect(find.byTooltip('Keyboard'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    await tester.tap(find.text('Touchpad'));
    await tester.pump();
    expect(fake.clicks, 1);
    await tester.tap(find.text('Arrows · OK'));
    await tester.pumpAndSettle();
    expect(find.text('Navigation'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
  });
}
