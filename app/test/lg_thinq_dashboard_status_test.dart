import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_thinq_api.dart';
import 'package:taptether/lg_thinq_dashboard_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  const refrigerator = LgThinQDevice(
    id: 'fridge1', name: 'Refrigerator',
    type: 'DEVICE_REFRIGERATOR', model: '2REF11EIIN__2',
  );
  const washer = LgThinQDevice(
    id: 'washer1', name: 'Top Load Washer', type: 'DEVICE_WASHER',
  );
  const dryer = LgThinQDevice(
    id: 'dryer1', name: 'Dryer', type: 'DEVICE_DRYER',
  );

  test('refrigerator shows Fahrenheit setpoints, not measured temperatures',
      () {
    final state = {
      'temperatureInUnits': [
        {'locationName': 'FREEZER',
          'targetTemperatureC': -23, 'targetTemperatureF': -7},
        {'locationName': 'FRIDGE',
          'targetTemperatureC': 1, 'targetTemperatureF': 33},
      ],
      'temperature': [
        {'locationName': 'FREEZER', 'targetTemperature': -7},
        {'locationName': 'FRIDGE', 'targetTemperature': 33},
      ],
    };
    expect(ThinQDashboardStatus.fromState(refrigerator, state).label,
        'Fridge 33°F · Freezer -7°F');
    expect(ThinQDashboardStatus.fromState(refrigerator, {
      'temperatureInUnits': [
        {'locationName': 'FREEZER', 'targetTemperatureC': -18},
        {'locationName': 'FRIDGE', 'targetTemperatureC': 3},
      ],
    }).label, 'Fridge 3°C · Freezer -18°C');
    expect(ThinQDashboardStatus.fromState(
        refrigerator, {'temperature': []}).label,
        'Temperatures unavailable');
  });

  test('washer shows running cycle and remaining time', () {
    final status = {
      'property': [
        {
          'location': {'locationName': 'MAIN'},
          'runState': {'currentState': 'WASHING'},
          'timer': {'remainHour': 1, 'remainMinute': 5},
        },
      ],
    };
    expect(ThinQDashboardStatus.fromState(washer, status).label,
        'Washing · 65 min left');
    expect(ThinQDashboardStatus.fromState(washer,
        {'runState': {'currentState': 'END'}}).label,
        'Cycle complete');
  });

  test('dryer does not present idle timer as active countdown', () {
    final off = {
      'runState': {'currentState': 'POWER_OFF'},
      'timer': {'remainHour': 0, 'remainMinute': 57},
    };
    expect(ThinQDashboardStatus.fromState(dryer, off).label,
        'Powered off');
    final active = {
      'runState': {'currentState': 'DRYING'},
      'timer': {'remainHour': 0, 'remainMinute': 28},
    };
    expect(ThinQDashboardStatus.fromState(dryer, active).label,
        'Drying · 28 min left');
    expect(ThinQDashboardStatus.fromState(dryer, {}).label,
        'Status unavailable');
  });

  test('custom names persist across re-enabling and simulated rediscovery',
      () async {
    final store = LgThinQStorage();
    await store.setEnabled(refrigerator, true);
    await store.renameDevice(refrigerator.id, 'Kitchen Fridge');
    expect((await store.enabledDevices()).single.name, 'Kitchen Fridge');
    await store.setEnabled(refrigerator, false);
    await store.setEnabled(refrigerator, true);
    expect((await store.enabledDevices()).single.name, 'Kitchen Fridge');
    expect((await store.localNames())[refrigerator.id], 'Kitchen Fridge');
  });

  test('invalid names are rejected and disconnect clears aliases', () async {
    final store = LgThinQStorage();
    await expectLater(store.renameDevice('fridge1', ''), throwsFormatException);
    await expectLater(store.renameDevice('fridge1', 'a' * 51),
        throwsFormatException);
    await store.renameDevice('fridge1', 'Family Fridge');
    await store.disconnect();
    expect(await store.localNames(), isEmpty);
  });
}
