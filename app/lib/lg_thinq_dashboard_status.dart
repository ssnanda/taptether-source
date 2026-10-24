import 'lg_thinq_api.dart';
import 'lg_thinq_cycle_history.dart';
import 'lg_thinq_features.dart';

/// Short, read-only dashboard summaries from an actual ThinQ status response.
/// No profile or inferred current sensor temperature is required.
class ThinQDashboardStatus {
  const ThinQDashboardStatus(this.label);
  final String label;

  static ThinQDashboardStatus fromState(LgThinQDevice device, Object? status) {
    final features = thinQFeatures(null, status);
    Object? value(String property, {String? zone}) {
      for (final feature in features) {
        if (feature.property == property &&
            (zone == null || feature.location == zone) &&
            feature.current != null) {
          return feature.current;
        }
      }
      return null;
    }

    if (device.type.toUpperCase().contains('REFRIGERATOR')) {
      String? target(List<String> locations) {
        for (final location in locations) {
          final fahrenheit = value('targetTemperatureF', zone: location);
          if (fahrenheit is num) return '${_number(fahrenheit)}°F';
          final celsius = value('targetTemperatureC', zone: location);
          if (celsius is num) return '${_number(celsius)}°C';
        }
        return null;
      }
      final fridge = target(const ['FRIDGE', 'REFRIGERATOR']);
      final freezer = target(const ['FREEZER']);
      if (fridge != null && freezer != null) {
        return ThinQDashboardStatus('Fridge $fridge · Freezer $freezer');
      }
      if (fridge != null) return ThinQDashboardStatus('Fridge $fridge');
      if (freezer != null) return ThinQDashboardStatus('Freezer $freezer');
      return const ThinQDashboardStatus('Temperatures unavailable');
    }

    final state = thinQState(features);
    if (state == null) {
      return const ThinQDashboardStatus('Status unavailable');
    }
    const labels = <String, String>{
      'POWER_OFF': 'Powered off',
      'OFF': 'Powered off',
      'STANDBY': 'Standby',
      'READY': 'Ready',
      'WASHING': 'Washing',
      'RINSING': 'Rinsing',
      'SPINNING': 'Spinning',
      'DRYING': 'Drying',
      'PAUSED': 'Paused',
      'PAUSE': 'Paused',
      'END': 'Cycle complete',
      'DONE': 'Cycle complete',
      'COMPLETE': 'Cycle complete',
      'COMPLETED': 'Cycle complete',
      'ERROR': 'Check appliance',
    };
    final label = labels[state] ?? _humanize(state);
    final active = thinQIsRunning(state) ||
        state == 'PAUSED' || state == 'PAUSE';
    if (!active) {
      // Some dryers retain the last program's 57-minute timer even when OFF.
      return ThinQDashboardStatus(label);
    }
    final remaining = thinQMinutes(features, 'remainHour', 'remainMinute');
    if (remaining != null && remaining > 0) {
      return ThinQDashboardStatus('$label · $remaining min left');
    }
    return ThinQDashboardStatus(label);
  }

  static String _number(num value) =>
      value == value.roundToDouble() ? value.toInt().toString()
          : value.toString();

  static String _humanize(String raw) {
    final text = raw.replaceAll('_', ' ').toLowerCase();
    if (text.isEmpty) return 'Status unavailable';
    return '${text[0].toUpperCase()}${text.substring(1)}';
  }
}
