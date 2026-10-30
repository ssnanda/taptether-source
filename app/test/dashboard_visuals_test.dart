import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/dashboard_visuals.dart';

void main() {
  testWidgets('appliance tiles keep temperature and action controls',
      (tester) async {
    var opened = false;
    var alerted = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      Builder(builder: (context) =>
        TapTetherDashboardVisuals.applianceCard(context,
        key: const ValueKey('lg-thinq-fridge'),
        id: 'fridge',
        name: 'Refrigerator',
        status: 'Fridge 33°F · Freezer -7°F',
        icon: Icons.kitchen_rounded,
        accent: TapTetherDashboardVisuals.blue,
        accentEnd: const Color(0xFF50BDF8),
        onTap: () => opened = true,
        actions: [IconButton(
          key: const ValueKey('lg-thinq-alert-fridge'),
          onPressed: () => alerted = true,
          icon: const Icon(Icons.notifications_none_rounded),
        )],
      )),
    )));
    expect(find.text('Refrigerator'), findsOneWidget);
    expect(find.text('Fridge 33°F · Freezer -7°F'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg-thinq-alert-fridge')));
    expect(alerted, isTrue);
    await tester.tap(find.text('Refrigerator'));
    expect(opened, isTrue);
  });

  testWidgets('device counters display saved totals', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Builder(builder: (context) =>
        TapTetherDashboardVisuals.deviceSummary(context,
          computers: 5, televisions: 1, xbox: 0)),
    )));
    expect(find.text('5'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('computers'), findsOneWidget);
  });
}
