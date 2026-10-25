import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/fridge_temperature.dart';

void main() {
  test('fridge/freezer reported setpoints are kept separate by zone', () {
    final data = {
      'temperatureInUnits': [
        {'locationName': 'FRIDGE',
          'targetTemperatureF': 36, 'targetTemperatureC': 2},
        {'locationName': 'FREEZER',
          'targetTemperatureF': -2, 'targetTemperatureC': -19},
      ],
    };
    final readings = fridgeReadings(data);
    expect(readings, hasLength(2));
    expect(readings.first.identity, 'FREEZER:target');
    expect(readings.last.identity, 'FRIDGE:target');
    expect(readings.last.unit, 'F');
    expect(readings.last.text, '36°F');
  });

  test('measured temperatures and target setpoints never mix', () {
    final readings = fridgeReadings({
      'temperatureInUnits': [
        {'locationName': 'FRIDGE',
          'currentTemperatureF': 44, 'targetTemperatureF': 36},
        {'locationName': 'FREEZER',
          'temperatureF': -1, 'targetTemperatureF': -2},
      ],
    });
    expect(readings, hasLength(4));
    expect(readings.where((r) => r.kind == 'actual'), hasLength(2));
    expect(readings.where((r) => r.kind == 'target'), hasLength(2));
  });

  test('first sample is baseline and unchanged readings have no alert', () {
    final now = fridgeReadings({
      'temperatureInUnits': [
        {'locationName': 'FRIDGE', 'targetTemperatureF': 37},
      ],
    });
    expect(compareFridgeReadings({}, now), isEmpty);
    expect(compareFridgeReadings({
      now.single.identity: now.single,
    }, now), isEmpty);
  });

  test('changing a setpoint produces change, not measured-temp alert', () {
    final before = FridgeTemperatureReading(
        zone: 'FRIDGE', kind: 'target', value: 37, unit: 'F');
    final after = FridgeTemperatureReading(
        zone: 'FRIDGE', kind: 'target', value: 39, unit: 'F');
    final changed = compareFridgeReadings({
      before.identity: before,
    }, [after]);
    expect(changed.single.after.kind, 'target');
    expect(changed.single.before.text, '37°F');
    expect(changed.single.after.text, '39°F');
  });

  test('unit switch is baseline reset, not a temperature alarm', () {
    const fahrenheit = FridgeTemperatureReading(
        zone: 'FREEZER', kind: 'actual', value: 0, unit: 'F');
    const celsius = FridgeTemperatureReading(
        zone: 'FREEZER', kind: 'actual', value: -18, unit: 'C');
    expect(compareFridgeReadings({
      fahrenheit.identity: fahrenheit,
    }, [celsius]), isEmpty);
  });
}
