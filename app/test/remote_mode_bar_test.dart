import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/remote_mode_bar.dart';

void main() {
  testWidgets('single compact row fits a narrow portrait phone',
      (tester) async {
    tester.view.physicalSize = const Size(375, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selected;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: RemoteModeBar(
          primaryMode: 'remote', visualMode: 'snapshot',
          captureAvailable: true,
          onPrimaryMode: (mode) => selected = mode,
          onVisualMode: (mode) => selected = mode,
        ))),
    )));
    expect(find.byKey(const ValueKey('one-row-remote-navigation')),
        findsOneWidget);
    expect(find.text('Remote'), findsOneWidget);
    expect(find.text('Slides'), findsOneWidget);
    expect(find.text('Media'), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-view-mode-switcher')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('primary-mode-media')));
    expect(selected, 'media');
    await tester.tap(find.byKey(
        const ValueKey('screen-view-mode-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live').last);
    expect(selected, 'live');
  });

  testWidgets('trackpad remains available without screen capture',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      RemoteModeBar(
        primaryMode: 'remote', visualMode: 'trackpad',
        captureAvailable: false,
        onPrimaryMode: (_) {}, onVisualMode: (_) {},
      ),
    )));
    await tester.tap(find.byKey(
        const ValueKey('screen-view-mode-switcher')));
    await tester.pumpAndSettle();
    final snapshot = tester.widget<PopupMenuItem<String>>(find.ancestor(
      of: find.text('Snapshot'),
      matching: find.byType(PopupMenuItem<String>),
    ));
    expect(snapshot.enabled, false);
  });
}
