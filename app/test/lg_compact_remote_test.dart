import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_compact_remote.dart';
import 'package:taptether/lg_webos_client.dart';

class FakeLgRemote extends LgWebOsClient {
  FakeLgRemote() : super(const LgTvDevice(
    host: '192.168.68.62', name: 'Family Room TV', clientKey: 'saved'));

  int clicks = 0;
  final List<String> mediaCommands = [];
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
  Future<void> button(String name) async {
    if (name == 'PLAY' || name == 'PAUSE') mediaCommands.add(name);
  }
  @override
  Future<void> launchApp(String appId) async {}
}

void main() {
  testWidgets('one Play/Pause control alternates distinct media actions',
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
    expect(find.byKey(const ValueKey('lg-media-play-pause')),
        findsOneWidget);
    expect(find.byTooltip('Pause / Play'), findsOneWidget);
    expect(find.byTooltip('Play'), findsNothing);
    expect(find.byTooltip('Pause'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('lg-media-play-pause')));
    await tester.pump();
    expect(fake.mediaCommands, ['PAUSE']);
    expect(find.byTooltip('Play / Pause'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lg-media-play-pause')));
    await tester.pump();
    expect(fake.mediaCommands, ['PAUSE', 'PLAY']);
    expect(find.byKey(const ValueKey('lg-media-play-pause')),
        findsOneWidget);
  });

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
    expect(find.byTooltip('Arrows and OK'), findsOneWidget);
    expect(find.byTooltip('Keyboard'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    await tester.tap(find.text('Touchpad'));
    await tester.pump();
    expect(fake.clicks, 1);
    await tester.tap(find.byTooltip('Arrows and OK'));
    await tester.pumpAndSettle();
    expect(find.text('Navigation'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
  });
}
