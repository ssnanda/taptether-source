import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/main.dart';

void main() {
  testWidgets('TapTether shows pairing screen', (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    expect(find.text('Pair with a computer agent'), findsOneWidget);
  });
}
