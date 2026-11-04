import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'govee_api.dart';

/// User-defined organization; never inferred from the device model or
/// manufacturer cloud account. Entries are tied to stable Govee device IDs.
class GoveePlacement {
  const GoveePlacement({this.location = '', this.room = ''});

  final String location;
  final String room;

  bool get isEmpty => location.isEmpty && room.isEmpty;

  Map<String, String> toJson() => {
    'location': location,
    'room': room,
  };

  factory GoveePlacement.fromJson(Object? value) {
    if (value is! Map) return const GoveePlacement();
    String cleaned(Object? text) {
      final label = text?.toString().trim() ?? '';
      return label.length <= 60 ? label : label.substring(0, 60);
    }
    return GoveePlacement(
      location: cleaned(value['location']),
      room: cleaned(value['room']),
    );
  }
}

String goveeDeviceKey(GoveeDevice device) =>
    '${device.sku}|${device.id}';

String goveeGroupName(GoveePlacement placement) {
  if (placement.location.isNotEmpty) return placement.location;
  if (placement.room.isNotEmpty) return placement.room;
  return 'Unassigned';
}

/// Location wins as the primary group; without a location, room becomes the
/// heading. This keeps users with one home and multiple rooms organized.
Map<String, List<GoveeDevice>> goveeGroups(
  List<GoveeDevice> devices,
  Map<String, GoveePlacement> placements,
) {
  final result = <String, List<GoveeDevice>>{};
  for (final device in devices) {
    final group = goveeGroupName(
      placements[goveeDeviceKey(device)] ?? const GoveePlacement());
    result.putIfAbsent(group, () => []).add(device);
  }
  for (final values in result.values) {
    values.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
  return Map.fromEntries(result.entries.toList()
    ..sort((a, b) {
      if (a.key == 'Unassigned') return 1;
      if (b.key == 'Unassigned') return -1;
      return a.key.toLowerCase().compareTo(b.key.toLowerCase());
    }));
}

/// Stored only on this phone in its iOS secure storage, not sent to Govee.
class GoveePlacementStore {
  GoveePlacementStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'taptether_govee_placements_v1';
  final FlutterSecureStorage _storage;

  Future<Map<String, GoveePlacement>> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return {};
      return parsed.map((id, value) =>
        MapEntry(id.toString(), GoveePlacement.fromJson(value)));
    } on FormatException {
      return {};
    }
  }

  Future<void> save(Map<String, GoveePlacement> placements) async {
    final normalized = <String, Map<String, String>>{};
    for (final entry in placements.entries) {
      if (entry.value.isEmpty) continue;
      normalized[entry.key] = entry.value.toJson();
    }
    await _storage.write(key: key, value: jsonEncode(normalized));
  }
}
