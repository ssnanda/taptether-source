import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'mag254_protocol.dart';
import 'tcl_google_tv_store.dart' show validTclGoogleTvHost;

/// MAG254 identity and TV pairing code are stored in iOS Keychain.
class Mag254Device {
  const Mag254Device({
    required this.host,
    required this.name,
    required this.deviceId,
    this.pairingCode = '',
  });

  final String host;
  final String name;
  final String deviceId;
  final String pairingCode;

  bool get paired => RegExp(r'^\d{6}$').hasMatch(pairingCode) &&
      RegExp(r'^[a-f0-9]{16}$').hasMatch(deviceId);

  Mag254Device copyWith({String? host, String? name, String? pairingCode}) =>
      Mag254Device(
        host: host ?? this.host,
        name: name ?? this.name,
        deviceId: deviceId,
        pairingCode: pairingCode ?? this.pairingCode,
      );

  Map<String, dynamic> toJson() => {
    'host': host, 'name': name, 'deviceId': deviceId,
    'pairingCode': pairingCode,
  };

  factory Mag254Device.fromJson(Map<String, dynamic> map) {
    final host = (map['host'] ?? '').toString();
    final deviceId = (map['deviceId'] ?? '').toString();
    if (!validTclGoogleTvHost(host) ||
        !RegExp(r'^[a-f0-9]{16}$').hasMatch(deviceId)) {
      throw const FormatException('Invalid saved MAG254 identity.');
    }
    return Mag254Device(
      host: host,
      name: (map['name'] ?? 'MAG254 IPTV Box').toString(),
      deviceId: deviceId,
      pairingCode: (map['pairingCode'] ?? '').toString(),
    );
  }
}

class Mag254Store {
  Mag254Store({FlutterSecureStorage? storage})
      : _secure = storage ?? const FlutterSecureStorage();

  static const key = 'taptether.mag254.pairings.v1';
  final FlutterSecureStorage _secure;

  Future<List<Mag254Device>> read() async {
    final raw = await _secure.read(key: key);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('Invalid saved MAG data');
    return decoded.whereType<Map>().map((item) =>
        Mag254Device.fromJson(Map<String, dynamic>.from(item))).toList();
  }

  Future<void> save(Mag254Device device) async {
    if (!validTclGoogleTvHost(device.host) ||
        device.name.trim().isEmpty || device.name.length > 80 ||
        !RegExp(r'^[a-f0-9]{16}$').hasMatch(device.deviceId)) {
      throw const FormatException('Enter a valid local MAG254 address.');
    }
    final items = await read();
    final index = items.indexWhere((existing) =>
        existing.deviceId == device.deviceId || existing.host == device.host);
    if (index == -1) {
      if (items.length >= 32) {
        throw const FormatException('Maximum 32 saved MAG boxes');
      }
      items.add(device);
    } else {
      items[index] = device;
    }
    await _secure.write(key: key,
        value: jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  Future<void> remove(Mag254Device device) async {
    final all = await read();
    all.removeWhere((item) => item.deviceId == device.deviceId);
    await _secure.write(key: key,
        value: jsonEncode(all.map((e) => e.toJson()).toList()));
  }
}

Future<bool> mag254Responds(String host) async {
  if (!validTclGoogleTvHost(host)) return false;
  try {
    final socket = await Socket.connect(host, Mag254Protocol.port,
        timeout: const Duration(milliseconds: 750));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}
