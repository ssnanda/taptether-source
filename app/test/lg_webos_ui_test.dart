import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_webos_screen.dart';

void main() {
  testWidgets('manual LG IP address supports dot entry with number keypad',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LgWebOsScreen()));
    final input = find.byType(TextField);
    expect(input, findsOneWidget);
    final field = tester.widget<TextField>(input);
    expect(field.keyboardType,
        const TextInputType.numberWithOptions(decimal: true));
    await tester.enterText(input, '192');
    await tester.tap(find.byTooltip('Insert IP address dot'));
    await tester.pump();
    expect(find.text('192.'), findsOneWidget);
  });
}
