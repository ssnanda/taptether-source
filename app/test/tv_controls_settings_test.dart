import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/tv_controls_settings_screen.dart';

void main() {
  testWidgets('TV settings offer both Lock Screen layouts and Control Center guide',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: TvControlsSettingsScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Lock Screen layout'), findsOneWidget);
    expect(find.text('Compact'), findsOneWidget);
    expect(find.text('Wide'), findsOneWidget);
    expect(find.text('Control Center'), findsOneWidget);
    expect(find.textContaining('Add a Control'), findsOneWidget);
    expect(find.textContaining('all ten actions'), findsOneWidget);
    await tester.tap(find.text('Wide'));
    await tester.pumpAndSettle();
    expect(find.textContaining('larger buttons'), findsOneWidget);
  });
}
