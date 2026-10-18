import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:taptether/visual_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/visual_surface.dart';

void main() {
  testWidgets('Zoomed image pans with one finger instead of moving cursor',
      (tester) async {
    final cursorMovements = <Offset>[];
    final remoteTaps = <(int, int)>[];
    final frame = ScreenFrame(base64Decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABIMDRANCxIQDhAUExIVGywdGxgYGzYnKSAsQDlEQz85Pj1HUGZXR0thTT0+WXlaYWltcnNyRVV9hnxvhWZwcm7/2wBDARMUFBsXGzQdHTRuST5Jbm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm7/wAARCAAJABADASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAABP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AIYBYT//2Q=='), 1280, 720);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Center(child: SizedBox(width: 400,
        child: VisualSurface(height: 300, frame: frame,
          live: true, busy: false, error: null, onRefresh: () {},
          onTap: (x, y, button) => remoteTaps.add((x, y)),
          onClick: (_) {},
          onMove: cursorMovements.add,
          onScroll: (_) {},
        ))),
    )));
    await tester.tap(find.byKey(const ValueKey('visual-zoom-in')));
    await tester.pump();
    expect(find.byKey(const ValueKey('visual-reset-zoom')), findsOneWidget);
    await tester.drag(find.byType(VisualSurface), const Offset(80, 0));
    await tester.pump();
    expect(cursorMovements, isEmpty);
    await tester.tapAt(tester.getCenter(find.byType(VisualSurface)));
    await tester.pump();
    expect(remoteTaps, isNotEmpty);
    expect(remoteTaps.last.$1, lessThan(5000));
    await tester.tap(find.byKey(const ValueKey('visual-reset-zoom')));
    await tester.pump();
    expect(find.byKey(const ValueKey('visual-reset-zoom')), findsNothing);
    await tester.drag(find.byType(VisualSurface), const Offset(25, 0));
    await tester.pump();
    expect(cursorMovements, isNotEmpty);
  });


  for (final live in [false, true]) {
    testWidgets(
        '${live ? "Live" : "Snapshot"} keeps touchpad dragging and '
        'clicking available before first video frame', (tester) async {
      final movement = <Offset>[];
      final clicks = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: VisualSurface(
          height: 260,
          frame: null,
          live: live,
          busy: false,
          error: null,
          onRefresh: () {},
          onTap: (x, y, button) {},
          onMove: movement.add,
          onClick: clicks.add,
          onScroll: (_) {},
        ))),
      ));
      await tester.drag(find.byType(VisualSurface), const Offset(45, 20));
      await tester.pump();
      expect(movement, isNotEmpty);
      expect(movement.map((event) => event.dx).reduce((a, b) => a + b),
          greaterThan(0));
      await tester.tap(find.byType(VisualSurface));
      await tester.pump();
      expect(clicks, contains('left'));
    });
  }
}
