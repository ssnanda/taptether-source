import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Each computer's token and TLS pin remain in iOS Keychain/Android secure
/// storage. No private credential is copied into ordinary app preferences.
class SavedComputer {
  const SavedComputer({
    required this.id,
    required this.name,
    required this.host,
    required this.token,
    required this.fingerprint,
    this.platform = 'computer',
  });

  final String id;
  final String name;
  final String host;
  final String token;
  final String fingerprint;
  final String platform;

  Map<String, String> toJson() => {
    'id': id, 'name': name, 'host': host, 'token': token,
    'fingerprint': fingerprint, 'platform': platform,
  };

  static SavedComputer fromJson(Map<String, dynamic> data) {
    String value(String key) => data[key] is String ? data[key] as String : '';
    final computer = SavedComputer(
      id: value('id'), name: value('name'), host: value('host'),
      token: value('token'), fingerprint: value('fingerprint'),
      platform: value('platform'),
    );
    if (computer.id.isEmpty || computer.host.isEmpty ||
        computer.token.length < 20 || computer.fingerprint.length != 64) {
      throw const FormatException('Invalid saved computer');
    }
    return computer;
  }

  static String newId() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

class ComputerStore {
  ComputerStore({FlutterSecureStorage? secureStorage})
      : _storage = secureStorage ?? const FlutterSecureStorage();

  static const _key = 'taptether.trusted.computers.v1';
  final FlutterSecureStorage _storage;

  Future<List<SavedComputer>> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('Invalid saved devices');
    return decoded
        .whereType<Map>()
        .map((entry) => SavedComputer.fromJson(Map<String, dynamic>.from(entry)))
        .toList();
  }

  Future<List<SavedComputer>> upsert(SavedComputer device) async {
    final devices = await read();
    devices.removeWhere((existing) =>
        existing.id == device.id || existing.host == device.host);
    devices.insert(0, device);
    if (devices.length > 25) devices.removeRange(25, devices.length);
    await _storage.write(
      key: _key, value: jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
    return devices;
  }

  Future<List<SavedComputer>> remove(String id) async {
    final devices = await read();
    devices.removeWhere((d) => d.id == id);
    await _storage.write(
      key: _key, value: jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
    return devices;
  }
}
