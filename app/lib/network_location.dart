
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'lan_scan.dart';

const deviceLocations = <String, String>{
  'home': 'Home', 'office': 'Office', 'other': 'Other',
};

/// User-assigned LAN categories. No GPS, cloud tracking or telemetry.
class NetworkLocationStore {
  NetworkLocationStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();
  static const _key = 'taptether.network.locations.v1';
  final FlutterSecureStorage _storage;

  /// Prefer Wi-Fi SSID where available. For privacy-restricted platforms,
  /// fall back to CIDR. Two unrelated networks with the same CIDR cannot be
  /// distinguished automatically; users can always override the filter.
  String? identifier(DetectedLanRange? range) {
    if (range == null) return null;
    final ssid = range.ssid?.replaceAll('"', '').trim();
    if (ssid != null && ssid.isNotEmpty && ssid != '<unknown ssid>') {
      return 'wifi:$ssid:${range.cidr}';
    }
    return 'cidr:${range.cidr}';
  }

  Future<Map<String, String>> _read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return {};
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return {};
      return parsed.map((key, value) =>
          MapEntry(key.toString(), value.toString()))
        ..removeWhere((_, value) => !deviceLocations.containsKey(value));
    } catch (_) {
      return {};
    }
  }

  Future<String?> locationFor(DetectedLanRange? network) async {
    final id = identifier(network);
    if (id == null) return null;
    return (await _read())[id];
  }

  Future<void> assign(DetectedLanRange network, String location) async {
    if (!deviceLocations.containsKey(location)) {
      throw ArgumentError.value(location, 'location');
    }
    final data = await _read();
    final id = identifier(network);
    if (id == null) return;
    data[id] = location;
    await _storage.write(key: _key, value: jsonEncode(data));
  }
}
