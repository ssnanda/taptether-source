import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/upside_down_app_rotation.dart';

void main() {
  testWidgets('upside-down event rotates the app without rebuilding its child',
      (tester) async {
    final orientations = StreamController<bool>.broadcast();
    addTearDown(orientations.close);
    var childBuilds = 0;

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => UpsideDownAppRotation(
        orientationStream: orientations.stream,
        child: Builder(builder: (context) {
          childBuilds++;
          return const Text('TV remote');
        }),
      ),
      home: const SizedBox.shrink(),
    ));

    RotatedBox rotated() => tester.widget<RotatedBox>(
        find.byKey(const ValueKey('taptether-physical-orientation')));
    expect(rotated().quarterTurns, 0);
    expect(find.text('TV remote'), findsOneWidget);

    orientations.add(true);
    await tester.pump();
    expect(rotated().quarterTurns, 2);
    expect(find.text('TV remote'), findsOneWidget);

    orientations.add(false);
    await tester.pump();
    expect(rotated().quarterTurns, 0);
    expect(find.text('TV remote'), findsOneWidget);
    expect(childBuilds, greaterThanOrEqualTo(1));
  });

  testWidgets('portrait inverted safe-area insets are swapped',
      (tester) async {
    final orientations = StreamController<bool>.broadcast();
    addTearDown(orientations.close);

    EdgeInsets? observedPadding;
    EdgeInsets? observedViewPadding;

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.fromLTRB(1, 59, 2, 34),
          viewPadding: const EdgeInsets.fromLTRB(1, 59, 2, 34),
        ),
        child: UpsideDownAppRotation(
          orientationStream: orientations.stream,
          child: Builder(builder: (context) {
            observedPadding = MediaQuery.paddingOf(context);
            observedViewPadding = MediaQuery.viewPaddingOf(context);
            return const Text('meter');
          }),
        ),
      ),
      home: const SizedBox.shrink(),
    ));

    expect(observedPadding,
        const EdgeInsets.fromLTRB(1, 59, 2, 34));

    orientations.add(true);
    await tester.pump();
    expect(observedPadding,
        const EdgeInsets.fromLTRB(2, 34, 1, 59));
    expect(observedViewPadding,
        const EdgeInsets.fromLTRB(2, 34, 1, 59));
  });
}
