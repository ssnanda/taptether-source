import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/visual_surface.dart';

void main() {
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
