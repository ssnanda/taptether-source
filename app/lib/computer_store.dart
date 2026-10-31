import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'automatic_device_backup.dart';

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
    this.deviceId = '',
    this.location = 'other',
    this.customName = false,
    this.macAddress = '',
    this.dnsName = '',
  });

  final String id;
  final String name;
  final String host;
  final String token;
  final String fingerprint;
  final String platform;
  // Enrollment ID of the phone's public key; shared by multiple computers.
  // Never use as a unique computer identifier.
  final String deviceId;
  final String location;
  final bool customName;
  // MAC is optional and comes only from authenticated agent metadata.
  final String macAddress;
  // The verified agent's OS hostname, distinct from the user's nickname.
  // mDNS/DNS can relocate this agent; it never proves device identity.
  final String dnsName;

  Map<String, String> toJson() => {
    'id': id, 'name': name, 'host': host, 'token': token,
    'fingerprint': fingerprint, 'platform': platform,
    'deviceId': deviceId, 'location': location,
    'customName': customName.toString(),
    'macAddress': macAddress,
    'dnsName': dnsName,
  };

  static SavedComputer fromJson(Map<String, dynamic> data) {
    String value(String key) => data[key] is String ? data[key] as String : '';
    final computer = SavedComputer(
      id: value('id'), name: value('name'), host: value('host'),
      token: value('token'), fingerprint: value('fingerprint'),
      platform: value('platform'), deviceId: value('deviceId'),
      location: const {'home', 'office', 'other'}.contains(value('location'))
          ? value('location') : 'other',
      customName: value('customName') == 'true',
      macAddress: value('macAddress'),
      // Preserve the original machine hostname for pre-migration pairings.
      // A custom nickname must never be used as a DNS/mDNS lookup name.
      dnsName: value('dnsName').isNotEmpty ? value('dnsName')
          : (value('customName') == 'true' ? '' : value('name')),
    );
    if (computer.id.isEmpty || computer.host.isEmpty ||
        (computer.token.length < 20 && computer.deviceId.length != 32) ||
        computer.fingerprint.length != 64) {
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
    final devices = decoded
        .whereType<Map>()
        .map((entry) => SavedComputer.fromJson(Map<String, dynamic>.from(entry)))
        .toList();
    // A deviceId is the ID of *this phone's public key as enrolled on the
    // agent*. The SAME phone has the SAME deviceId on every Mac, Ubuntu and
    // Windows agent. It must NEVER identify or deduplicate computers.
    // Agent identity is the pinned TLS certificate fingerprint; the saved
    // record ID separately identifies the phone's local list entry.
    final seenIds = <String>{};
    final seenPins = <String>{};
    return devices.where((device) {
      final pin = device.fingerprint.toUpperCase();
      if (seenIds.contains(device.id) || seenPins.contains(pin)) {
        return false;
      }
      seenIds.add(device.id);
      seenPins.add(pin);
      return true;
    }).toList();
  }

  Future<List<SavedComputer>> upsert(SavedComputer device) async {
    final devices = await read();
    // Phone enrollment IDs are shared across all computers paired to this
    // phone. Only merge the same saved record or the same verified agent
    // certificate. Never merge by deviceId, hostname, MAC, or DHCP address.
    final pin = device.fingerprint.toUpperCase();
    devices.removeWhere((existing) =>
        existing.id == device.id ||
        (pin.length == 64 && existing.fingerprint.toUpperCase() == pin));
    devices.insert(0, device);
    if (devices.length > 25) devices.removeRange(25, devices.length);
    await _storage.write(
      key: _key, value: jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
    AutomaticDeviceBackup.instance.requestSoon();
    return devices;
  }

  Future<List<SavedComputer>> remove(String id) async {
    final devices = await read();
    devices.removeWhere((d) => d.id == id);
    await _storage.write(
      key: _key, value: jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
    AutomaticDeviceBackup.instance.requestSoon();
    return devices;
  }
}
