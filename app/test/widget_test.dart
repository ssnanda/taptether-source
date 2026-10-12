import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/main.dart';

void main() {
  testWidgets('TapTether reveals manual pairing when Add computer is tapped',
      (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    expect(find.text('My Devices'), findsOneWidget);
    expect(find.text('Pair with a computer agent'), findsNothing);
    await tester.tap(find.text('Add computer'));
    await tester.pump();
    expect(find.text('Pair with a computer agent'), findsOneWidget);
  });
}
