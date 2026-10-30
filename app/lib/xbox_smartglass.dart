import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'discovery.dart';
import 'lan_scan.dart';

/// Legacy Xbox One SmartGlass UDP discovery and standby wake only.
/// Newer Series X|S firmware is not guaranteed to respond.
/// Controller input requires a separate authenticated, encrypted session.
/// A discovery certificate fingerprint is a change detector, NOT proof that
/// the responding LAN host is the rightful owner of the Xbox identity.
class XboxConsole {
  const XboxConsole({
    required this.host,
    required this.name,
    required this.uuid,
    required this.certificateSha256,
    required this.liveId,
    this.location = 'other',
  });

  final String host;
  final String name;
  final String uuid;
  final String certificateSha256;
  final String liveId;
  final String location;

  XboxConsole copyWith({String? host, String? name, String? location}) =>
      XboxConsole(
        host: host ?? this.host,
        name: name ?? this.name,
        uuid: uuid,
        certificateSha256: certificateSha256,
        liveId: liveId,
        location: location ?? this.location,
      );

  Map<String, String> toJson() => {
        'host': host,
        'name': name,
        'uuid': uuid,
        'certificateSha256': certificateSha256,
        'liveId': liveId,
        'location': location,
      };

  static XboxConsole fromJson(Map<String, dynamic> json) => XboxConsole(
        host: (json['host'] as String?) ?? '',
        name: (json['name'] as String?) ?? 'Xbox',
        uuid: (json['uuid'] as String?) ?? '',
        certificateSha256: (json['certificateSha256'] as String?) ?? '',
        liveId: (json['liveId'] as String?) ?? '',
        location: (json['location'] as String?) ?? 'other',
      );
}

/// Safe parsing of the unencrypted DD01 discovery reply. No trust is granted
/// to the sender, even if it presents a plausible X.509 certificate.
XboxConsole? parseXboxDiscovery(List<int> packet, String host) {
  if (!isPrivateIPv4(host) || packet.length < 36 ||
      packet.length > 8192 || packet[0] != 0xdd || packet[1] != 0x01) {
    return null;
  }
  try {
    final bytes = Uint8List.fromList(packet);
    final view = ByteData.sublistView(bytes);
    final payloadLength = view.getUint16(2, Endian.big);
    if (view.getUint16(4, Endian.big) != 0 ||
        payloadLength != bytes.length - 6) {
      return null;
    }
    final flags = view.getUint32(6, Endian.big);
    if (flags & 0x08 != 0) return null; // certificate is pending
    if (view.getUint16(10, Endian.big) != 1) return null; // Xbox One family
    var offset = 14; // response's two reserved bytes after device type
    (String, int)? readString() {
      if (offset + 2 > bytes.length) return null;
      final size = view.getUint16(offset, Endian.big);
      offset += 2;
      if (size < 1 || size > 128 || offset + size + 1 > bytes.length ||
          bytes[offset + size] != 0) {
        return null;
      }
      final value = utf8.decode(bytes.sublist(offset, offset + size));
      offset += size + 1;
      return (value, offset);
    }

    final consoleName = readString();
    final uuid = readString();
    if (consoleName == null || uuid == null ||
        consoleName.$1.trim().isEmpty || uuid.$1.trim().isEmpty ||
        offset + 6 > bytes.length) {
      return null;
    }
    offset += 4; // last error
    final certificateSize = view.getUint16(offset, Endian.big);
    offset += 2;
    if (certificateSize < 64 || offset + certificateSize != bytes.length) {
      return null;
    }
    final certificate = bytes.sublist(offset);
    if (certificate.first != 0x30) return null; // DER SEQUENCE
    final liveId = xboxLiveIdFromDer(certificate);
    return XboxConsole(
      host: host,
      name: consoleName.$1.trim(),
      uuid: uuid.$1,
      certificateSha256: sha256.convert(certificate).toString(),
      liveId: liveId ?? '',
    );
  } catch (_) {
    return null;
  }
}

/// Locate the certificate Subject CN. The issuer's well-known CN is ignored.
/// This lightweight reader is not X.509 chain validation.
String? xboxLiveIdFromDer(List<int> certificate) {
  String? result;
  for (var index = 0; index + 7 < certificate.length; index++) {
    if (certificate[index] != 0x06 || certificate[index + 1] != 0x03 ||
        certificate[index + 2] != 0x55 || certificate[index + 3] != 0x04 ||
        certificate[index + 4] != 0x03) {
      continue;
    }
    final type = certificate[index + 5];
    if (type != 0x0c && type != 0x13 && type != 0x16) continue;
    final length = certificate[index + 6];
    if (length < 5 || length > 64 || index + 7 + length > certificate.length) {
      continue;
    }
    final value = String.fromCharCodes(
        certificate.sublist(index + 7, index + 7 + length));
    if (RegExp(r'^[A-Za-z0-9._-]{5,64}$').hasMatch(value)) result = value;
  }
  return result;
}

List<int> xboxDiscoveryPacket() => const <int>[
      0xdd, 0x00, 0x00, 0x0a, 0x00, 0x00, // simple header, version 0
      0, 0, 0, 0, // flags
      0, 6, // iPhone client
      0, 0, // minimum protocol version
      0, 2, // maximum version
    ];

List<int> xboxWakePacket(String liveId) {
  if (!RegExp(r'^[A-Za-z0-9._-]{5,64}$').hasMatch(liveId)) {
    throw const FormatException('An Xbox Live ID from discovery is required.');
  }
  final payload = utf8.encode(liveId);
  final size = payload.length + 3; // SGString: uint16 size + NUL
  return <int>[
    0xdd, 0x02, size >> 8, size & 0xff, 0, 2,
    payload.length >> 8, payload.length & 0xff, ...payload, 0,
  ];
}

/// Optional counters distinguish no UDP reply from a malformed legacy reply.
/// A response is never treated as authenticated pairing.
class XboxDiscoveryStats {
  int sent = 0;
  int replies = 0;
  int malformed = 0;
  int compatible = 0;
}

/// An explicit full-network scan sends one legacy discovery packet to every
/// local address in up to four /24 blocks, not just to multicast/broadcast.
/// Other, silent devices are detected separately by TCP port scanning.
List<String> xboxScanTargets(DetectedLanRange network,
    {int maxHosts = 1024}) {
  final found = <String>[];
  for (final prefix in network.scanPrefixes.take(4)) {
    final bounds = scanPrefixBounds(network, prefix);
    for (var host = bounds.startHost; host <= bounds.endHost; host++) {
      final ip = '$prefix.$host';
      if (ip != network.ip && lanRangeContains(network, ip)) {
        found.add(ip);
      }
      if (found.length >= maxHosts) return found;
    }
  }
  return found;
}

/// Only explicit user actions can initiate discovery. Never scan on startup.
Future<List<XboxConsole>> discoverXboxConsoles({
  String? targetIp,
  Duration duration = const Duration(milliseconds: 1600),
  bool fullNetwork = false,
  XboxDiscoveryStats? diagnostics,
}) async {
  final network = await detectLanRange();
  if (network == null) {
    throw StateError('Connect to Wi-Fi before searching for an Xbox.');
  }
  if (targetIp != null &&
      (!isPrivateIPv4(targetIp) || !lanRangeContains(network, targetIp))) {
    throw const FormatException('The Xbox IP must be on this Wi-Fi network.');
  }
  final found = <String, XboxConsole>{};
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final listener = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      final reply = datagram!;
      final ip = reply.address.address;
      if (reply.port != 5050 || !lanRangeContains(network, ip) ||
          (targetIp != null && !fullNetwork && ip != targetIp)) {
        continue;
      }
      if (diagnostics != null) diagnostics.replies++;
      final candidate = parseXboxDiscovery(reply.data, ip);
      if (candidate != null) {
        found[candidate.uuid] = candidate;
        if (diagnostics != null) diagnostics.compatible++;
      } else {
        if (diagnostics != null) diagnostics.malformed++;
      }
    }
  });
  try {
    final packet = xboxDiscoveryPacket();
    final endpoints = targetIp != null
        ? <String>[targetIp]
        : <String>['255.255.255.255',
            lanBroadcastAddress(network), '239.255.255.250'];
    for (final endpoint in endpoints.toSet()) {
      try {
        if (socket.send(packet, InternetAddress(endpoint), 5050) > 0) {
          if (diagnostics != null) diagnostics.sent++;
        }
      } on SocketException {
        // Some Wi-Fi networks forbid broadcast/multicast; use manual IP.
      }
    }
    if (fullNetwork) {
      final targets = xboxScanTargets(network);
      // Throttle to avoid overwhelming Wi-Fi and avoid unbounded scans.
      for (var i = 0; i < targets.length; i++) {
        try {
          if (socket.send(packet, InternetAddress(targets[i]), 5050) > 0) {
            if (diagnostics != null) diagnostics.sent++;
          }
        } on SocketException {
          // A single filtered destination must not abort the sweep.
        }
        if ((i + 1) % 24 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 24));
        }
      }
    }
    await Future<void>.delayed(duration);
  } finally {
    await listener.cancel();
    socket.close();
  }
  return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// Power on is best-effort only when Xbox is in network standby/Sleep mode.
Future<void> wakeXbox(XboxConsole console) async {
  final network = await detectLanRange();
  if (network == null || !lanRangeContains(network, console.host)) {
    throw StateError('Connect to the Wi-Fi network containing this Xbox.');
  }
  final packet = xboxWakePacket(console.liveId);
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  try {
    final endpoints = <String>{console.host, lanBroadcastAddress(network),
      '239.255.255.250'};
    for (var attempt = 0; attempt < 3; attempt++) {
      for (final endpoint in endpoints) {
        try {
          socket.send(packet, InternetAddress(endpoint), 5050);
        } on SocketException {
          // Unicast may still succeed when broadcast is filtered.
        }
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 140));
      }
    }
  } finally {
    socket.close();
  }
}

class XboxConsoleStore {
  XboxConsoleStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();
  static const key = 'taptether.xbox.consoles.v1';
  static const lastTargetKey = 'taptether.xbox.target-ip.v1';
  final FlutterSecureStorage _storage;

  Future<String?> lastTargetIp() async {
    final ip = await _storage.read(key: lastTargetKey);
    return ip != null && isPrivateIPv4(ip) ? ip : null;
  }

  Future<void> saveLastTargetIp(String ip) async {
    if (!isPrivateIPv4(ip)) {
      throw const FormatException('Expected a private Xbox LAN IP.');
    }
    await _storage.write(key: lastTargetKey, value: ip);
  }

  Future<List<XboxConsole>> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded.whereType<Map>().map((entry) =>
        XboxConsole.fromJson(Map<String, dynamic>.from(entry)))
        .where((item) => isPrivateIPv4(item.host) &&
            item.uuid.isNotEmpty &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(item.certificateSha256))
        .take(20).toList();
  }

  Future<void> save(XboxConsole candidate) async {
    if (!isPrivateIPv4(candidate.host) || candidate.uuid.isEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate.certificateSha256)) {
      throw const FormatException('Save only a discovered Xbox.');
    }
    final consoles = await read();
    for (final previous in consoles.where((item) =>
        item.uuid == candidate.uuid)) {
      if (previous.certificateSha256 != candidate.certificateSha256) {
        throw StateError('Xbox certificate changed. Remove the saved Xbox '
            'and verify it again at the console before saving.');
      }
    }
    final previous = consoles.where((item) => item.uuid == candidate.uuid);
    final name = previous.isEmpty ? candidate.name : previous.first.name;
    final location = previous.isEmpty ? candidate.location :
        previous.first.location;
    consoles.removeWhere((item) => item.uuid == candidate.uuid);
    consoles.insert(0, candidate.copyWith(name: name, location: location));
    await _storage.write(key: key, value: jsonEncode(
        consoles.take(20).map((device) => device.toJson()).toList()));
  }

  Future<void> remove(String uuid) async {
    final consoles = await read();
    consoles.removeWhere((item) => item.uuid == uuid);
    await _storage.write(key: key,
        value: jsonEncode(consoles.map((e) => e.toJson()).toList()));
  }
}