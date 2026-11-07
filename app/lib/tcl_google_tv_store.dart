import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A local, user-owned Google TV pairing. The client private key is sensitive:
/// the entire record is stored in iOS Keychain, not ordinary preferences.
class TclGoogleTv {
  const TclGoogleTv({
    required this.host,
    required this.name,
    this.certificatePem = '',
    this.privateKeyPem = '',
    this.serverFingerprint = '',
  });

  final String host;
  final String name;
  final String certificatePem;
  final String privateKeyPem;
  final String serverFingerprint;

  bool get paired => certificatePem.isNotEmpty &&
      privateKeyPem.isNotEmpty && serverFingerprint.length == 64;

  TclGoogleTv copyWith({
    String? name,
    String? certificatePem,
    String? privateKeyPem,
    String? serverFingerprint,
  }) => TclGoogleTv(
    host: host,
    name: name ?? this.name,
    certificatePem: certificatePem ?? this.certificatePem,
    privateKeyPem: privateKeyPem ?? this.privateKeyPem,
    serverFingerprint: serverFingerprint ?? this.serverFingerprint,
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'name': name,
    'certificatePem': certificatePem,
    'privateKeyPem': privateKeyPem,
    'serverFingerprint': serverFingerprint,
  };

  factory TclGoogleTv.fromJson(Map<String, dynamic> json) {
    final host = (json['host'] ?? '').toString();
    if (!validTclGoogleTvHost(host)) {
      throw const FormatException('Invalid TV host');
    }
    return TclGoogleTv(
      host: host,
      name: (json['name'] ?? 'TCL Google TV').toString(),
      certificatePem: (json['certificatePem'] ?? '').toString(),
      privateKeyPem: (json['privateKeyPem'] ?? '').toString(),
      serverFingerprint: (json['serverFingerprint'] ?? '').toString(),
    );
  }
}

/// TCL Google TV is controlled only on a private local network; no cloud
/// endpoint or public IP is ever accepted for pairing or command traffic.
bool validTclGoogleTvHost(String input) {
  if (!RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(input)) {
    return false;
  }
  final o = input.split('.').map(int.tryParse).toList();
  if (o.any((v) => v == null || v < 0 || v > 255)) return false;
  final a = o[0]!, b = o[1]!;
  if (o[3] == 0 || o[3] == 255) return false;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}

class TclGoogleTvStore {
  TclGoogleTvStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'taptether.tcl.google_tv.pairings.v1';
  final FlutterSecureStorage _storage;

  Future<List<TclGoogleTv>> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list.whereType<Map>().map((item) =>
          TclGoogleTv.fromJson(Map<String, dynamic>.from(item))).toList();
    } on FormatException {
      return [];
    }
  }

  Future<void> save(TclGoogleTv entry) async {
    if (!validTclGoogleTvHost(entry.host) ||
        entry.name.trim().isEmpty || entry.name.length > 80) {
      throw const FormatException('Enter a valid local TV IP and name.');
    }
    final all = await read();
    final index = all.indexWhere((tv) => tv.host == entry.host);
    if (index < 0) {
      if (all.length >= 32) {
        throw const FormatException('Maximum 32 saved Google TVs.');
      }
      all.add(entry);
    } else {
      all[index] = entry;
    }
    await _storage.write(key: key, value: jsonEncode(
        all.map((tv) => tv.toJson()).toList()));
  }

  Future<void> remove(String host) async {
    final all = await read();
    all.removeWhere((tv) => tv.host == host);
    await _storage.write(key: key, value: jsonEncode(
        all.map((tv) => tv.toJson()).toList()));
  }
}

Future<bool> tclGoogleTvPortResponds(String host) async {
  if (!validTclGoogleTvHost(host)) return false;
  try {
    final socket = await Socket.connect(host, 6466,
        timeout: const Duration(milliseconds: 850));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}
