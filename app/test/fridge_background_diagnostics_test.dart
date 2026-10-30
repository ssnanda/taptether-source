import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/fridge_alerts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('background monitor records actual OS wake and LG outcome', () async {
    final alerts = FridgeAlerts.instance;
    final initial = await alerts.backgroundDiagnostics();
    expect(initial['lastWake'], isEmpty);
    expect(initial['outcome'], 'No background LG check yet');

    await alerts.recordBackgroundWake();
    await alerts.recordBackgroundResult('LG checked 1 refrigerator');
    final after = await alerts.backgroundDiagnostics();
    expect(DateTime.tryParse(after['lastWake']!)?.isUtc, isTrue);
    expect(after['outcome'], 'LG checked 1 refrigerator');
  });

  test('not-registered background tasks are never described as run', () async {
    final alerts = FridgeAlerts.instance;
    await alerts.recordScheduleFailure();
    final diagnostics = await alerts.backgroundDiagnostics();
    expect(diagnostics['schedule'], 'Background task registration failed');
    expect(diagnostics['lastWake'], isEmpty);
  });
}
