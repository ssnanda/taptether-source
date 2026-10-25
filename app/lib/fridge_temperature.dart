import 'lg_thinq_features.dart';

/// Temperature readings from LG ThinQ state. "Target" means configured
/// setpoint, not a measured sensor temperature. Never conflate the two.
class FridgeTemperatureReading {
  const FridgeTemperatureReading({
    required this.zone,
    required this.kind,
    required this.value,
    required this.unit,
  });
  final String zone;
  final String kind; // actual or target
  final num value;
  final String unit;

  String get identity => '$zone:$kind';
  String get label => kind == 'target' ? 'setpoint' : 'temperature';
  String get text => '${_format(value)}°$unit';

  static String _format(num v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

List<FridgeTemperatureReading> fridgeReadings(Object? state) {
  final features = thinQFeatures(null, state);
  final readings = <String, FridgeTemperatureReading>{};
  final preferred = <String, String>{
    'currentTemperatureF': 'actual:F',
    'temperatureF': 'actual:F',
    'currentTemperatureC': 'actual:C',
    'temperatureC': 'actual:C',
    'targetTemperatureF': 'target:F',
    'targetTemperatureC': 'target:C',
  };
  for (final feature in features) {
    final rule = preferred[feature.property];
    if (rule == null || feature.current is! num) continue;
    final zone = (feature.location ?? '').toUpperCase();
    if (zone != 'FRIDGE' && zone != 'REFRIGERATOR' &&
        zone != 'FREEZER') continue;
    final canonical = zone == 'REFRIGERATOR' ? 'FRIDGE' : zone;
    final bits = rule.split(':');
    final kind = bits[0];
    final unit = bits[1];
    final key = '$canonical:$kind';
    final previous = readings[key];
    // Prefer Fahrenheit where LG reports both units.
    if (previous == null || (unit == 'F' && previous.unit != 'F')) {
      readings[key] = FridgeTemperatureReading(
        zone: canonical,
        kind: kind,
        value: feature.current as num,
        unit: unit,
      );
    }
  }
  return readings.values.toList()
    ..sort((a, b) => a.identity.compareTo(b.identity));
}

class FridgeTemperatureChange {
  const FridgeTemperatureChange(this.before, this.after);
  final FridgeTemperatureReading before;
  final FridgeTemperatureReading after;
}

/// First reading seeds baseline without notifying. Only the same unit and
/// same measurement type may be compared; changing units resets baseline.
List<FridgeTemperatureChange> compareFridgeReadings(
    Map<String, FridgeTemperatureReading> previous,
    List<FridgeTemperatureReading> current) {
  final changes = <FridgeTemperatureChange>[];
  for (final reading in current) {
    final older = previous[reading.identity];
    if (older != null && older.unit == reading.unit &&
        older.value != reading.value) {
      changes.add(FridgeTemperatureChange(older, reading));
    }
  }
  return changes;
}
