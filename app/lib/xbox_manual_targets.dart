import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'automatic_device_backup.dart';
import 'discovery.dart';

/// A user-saved address, NOT a network-discovered or authenticated Xbox.
/// Microsoft's Remote Play signs the user in separately, on Xbox's site.
class XboxManualTarget {
  const XboxManualTarget({
    required this.host,
    required this.name,
    this.location = 'other',
  });

  final String host;
  final String name;
  final String location;

  Map<String, String> toJson() => {
    'host': host,
    'name': name,
    'location': location,
  };

  factory XboxManualTarget.fromJson(Map<String, dynamic> map) =>
      XboxManualTarget(
        host: (map['host'] as String?) ?? '',
        name: (map['name'] as String?) ?? 'Xbox',
        location: (map['location'] as String?) ?? 'other',
      );
}

/// Save manually confirmed console IPs without fabricating a SmartGlass
/// certificate or claiming that a UDP probe authenticated the console.
class XboxManualTargetStore {
  XboxManualTargetStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'taptether.xbox.manual-targets.v1';
  final FlutterSecureStorage _storage;

  Future<List<XboxManualTarget>> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final seen = <String>{};
      return decoded.whereType<Map>().map((data) =>
          XboxManualTarget.fromJson(Map<String, dynamic>.from(data)))
          .where((device) => isPrivateIPv4(device.host) &&
              device.name.trim().isNotEmpty &&
              seen.add(device.host))
          .take(20).toList();
    } on FormatException {
      return [];
    }
  }

  Future<void> save(XboxManualTarget target) async {
    if (!isPrivateIPv4(target.host)) {
      throw const FormatException('Enter the Xbox local IPv4 address.');
    }
    final name = target.name.trim();
    if (name.isEmpty || name.length > 60) {
      throw const FormatException('Enter an Xbox name (up to 60 characters).');
    }
    final all = await read();
    all.removeWhere((e) => e.host == target.host);
    all.insert(0, XboxManualTarget(
      host: target.host,
      name: name,
      location: target.location,
    ));
    await _storage.write(key: key,
        value: jsonEncode(all.take(20).map((e) => e.toJson()).toList()));
    AutomaticDeviceBackup.instance.requestSoon();
  }

  Future<void> remove(String host) async {
    final all = await read();
    all.removeWhere((e) => e.host == host);
    await _storage.write(key: key,
        value: jsonEncode(all.map((e) => e.toJson()).toList()));
    AutomaticDeviceBackup.instance.requestSoon();
  }
}
