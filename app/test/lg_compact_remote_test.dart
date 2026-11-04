import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_compact_remote.dart';
import 'package:taptether/lg_webos_client.dart';

class FakeLgRemote extends LgWebOsClient {
  FakeLgRemote() : super(const LgTvDevice(
    host: '192.168.68.62', name: 'Family Room TV', clientKey: 'saved'));

  int clicks = 0;
  final List<String> mediaCommands = [];
  final List<String> remoteButtons = [];
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
    remoteButtons.add(name);
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

  testWidgets('TV captions open settings without claiming streaming toggles',
      (tester) async {
    final fake = FakeLgRemote();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 390, height: 640,
        child: LgCompactRemote(
          client: fake, device: fake.device, onError: (_) {})))));
    await tester.pump();
    expect(find.text('Snapshot'), findsNothing);
    expect(find.byKey(const ValueKey('lg-closed-captions')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg-closed-captions')));
    await tester.pumpAndSettle();
    expect(find.text('Closed captions (CC)'), findsOneWidget);
    expect(find.textContaining('streaming'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg-open-caption-settings')));
    await tester.pumpAndSettle();
    expect(fake.remoteButtons, contains('SETTINGS'));
  });

  testWidgets('phone sound level appears in TV header without a sheet',
      (tester) async {
    final fake = FakeLgRemote();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 390, height: 640,
        child: LgCompactRemote(
          client: fake, device: fake.device, onError: (_) {})))));
    await tester.pump();
    expect(find.byKey(const ValueKey('lg-phone-sound-meter')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('lg-phone-db-value')),
        findsOneWidget);
    expect(find.text('Start measuring'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('holding an arrow repeats and releasing stops it',
      (tester) async {
    final fake = FakeLgRemote();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 390, height: 600,
        child: LgCompactRemote(
          client: fake, device: fake.device, onError: (_) {})))));
    await tester.pump();
    await tester.tap(find.byTooltip('Arrows and OK'));
    await tester.pump();
    final up = find.byKey(const ValueKey('lg-dpad-up'));
    final gesture = await tester.startGesture(tester.getCenter(up));
    await tester.pump(const Duration(milliseconds: 750));
    final heldCount = fake.remoteButtons.where((key) => key == 'UP').length;
    expect(heldCount, greaterThan(1));
    await gesture.up();
    await tester.pump();
    final afterRelease = fake.remoteButtons.length;
    await tester.pump(const Duration(milliseconds: 700));
    expect(fake.remoteButtons.length, afterRelease);
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
    expect(find.byTooltip('Voice search'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    await tester.tap(find.text('Touchpad'));
    await tester.pump();
    expect(fake.clicks, 1);
    await tester.tap(find.byTooltip('Arrows and OK'));
    await tester.pump();
    expect(find.text('Navigation'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Touchpad'), findsNothing);
    expect(find.text('OK'), findsOneWidget);
    expect(find.byTooltip('Touchpad'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg-dpad-up')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lg-dpad-left')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lg-dpad-enter')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lg-dpad-right')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lg-dpad-down')));
    await tester.pump();
    expect(fake.remoteButtons,
        containsAllInOrder(['UP', 'LEFT', 'ENTER', 'RIGHT', 'DOWN']));
    await tester.tap(find.byTooltip('Touchpad'));
    await tester.pump();
    expect(find.text('Touchpad'), findsOneWidget);
    expect(find.text('OK'), findsNothing);
    expect(find.byTooltip('Arrows and OK'), findsOneWidget);
    expect(find.byKey(const ValueKey('lg-navigation-mode-toggle')),
        findsOneWidget);
    await tester.tap(find.text('Touchpad'));
    await tester.pump();
    expect(fake.clicks, 2);
  });
}
