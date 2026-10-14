import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'discovery.dart';

/// Unauthenticated discovery hints. Never trust these for pairing or control.
class LanProbeHost {
  const LanProbeHost(this.ip, this.name, this.method);
  final String ip;
  final String name;
  final String method;
}

bool _onPrefix(String address, String prefix) =>
    isPrivateIPv4(address) && address.startsWith('$prefix.');

String? _readName(Uint8List data, int index, List<int> next) {
  final labels = <String>[];
  var jumps = 0, consumed = false;
  while (index < data.length && jumps++ < 24) {
    final len = data[index];
    if (len == 0) {
      if (!consumed) next[0] = index + 1;
      return labels.join('.');
    }
    if (len & 0xc0 == 0xc0) {
      if (index + 1 >= data.length) return null;
      final target = ((len & 0x3f) << 8) | data[index + 1];
      if (!consumed) next[0] = index + 2;
      consumed = true;
      if (target >= data.length) return null;
      index = target;
      continue;
    }
    if (len & 0xc0 != 0 || len > 63 || index + 1 + len > data.length) {
      return null;
    }
    final segment = ascii.decode(data.sublist(index + 1, index + 1 + len),
        allowInvalid: true);
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,63}$').hasMatch(segment)) return null;
    labels.add(segment);
    index += len + 1;
    if (!consumed) next[0] = index;
  }
  return null;
}

/// Parse only A records in a bounded multicast DNS response.
Map<String, String> parseMdnsAddresses(List<int> bytes) {
  final result = <String, String>{};
  if (bytes.length < 12 || bytes.length > 4096) return result;
  final data = Uint8List.fromList(bytes);
  int word(int i) => (data[i] << 8) | data[i + 1];
  // Response flag and at most 64 questions/resource records.
  if (data[2] & 0x80 == 0) return result;
  final questions = word(4);
  final records = word(6) + word(8) + word(10);
  if (questions > 64 || records > 64) return result;
  var offset = 12;
  for (var i = 0; i < questions; i++) {
    final next = [offset];
    if (_readName(data, offset, next) == null || next[0] + 4 > data.length) {
      return {};
    }
    offset = next[0] + 4;
  }
  for (var i = 0; i < records; i++) {
    final next = [offset];
    final hostname = _readName(data, offset, next);
    if (hostname == null || next[0] + 10 > data.length) return result;
    final start = next[0];
    final kind = word(start);
    final size = word(start + 8);
    offset = start + 10;
    if (offset + size > data.length) return result;
    if (kind == 1 && size == 4 && hostname.endsWith('.local')) {
      final ip = data.sublist(offset, offset + 4).join('.');
      if (isPrivateIPv4(ip)) result[ip] = hostname;
    }
    offset += size;
  }
  return result;
}

LanProbeHost? parseSsdpHost(String sourceIp, List<int> payload) {
  if (!isPrivateIPv4(sourceIp) || payload.length > 4096) return null;
  final raw = latin1.decode(payload, allowInvalid: true);
  if (!raw.startsWith('HTTP/1.1 200') &&
      !raw.startsWith('NOTIFY * HTTP/1.1')) return null;
  final server = RegExp(r'^SERVER:\\s*(.+)$',
          caseSensitive: false, multiLine: true)
      .firstMatch(raw)?.group(1)?.trim();
  final usn = RegExp(r'^USN:\\s*(.+)$', caseSensitive: false, multiLine: true)
      .firstMatch(raw)?.group(1)?.trim();
  final label = server ?? usn ?? 'UPnP device';
  // No attacker-controlled markup, line breaks or oversized labels.
  final safe = label.replaceAll(RegExp(r'[^\\w .()\\/-]'), '').trim();
  return LanProbeHost(sourceIp,
      safe.isEmpty ? 'UPnP device' : safe.substring(0, safe.length.clamp(0, 60)),
      'SSDP');
}

List<int> _mdnsQuestion(String name) {
  final out = <int>[0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
  for (final part in name.split('.')) {
    out.add(part.length);
    out.addAll(ascii.encode(part));
  }
  // QU bit requests an answer to the probe's ephemeral UDP port.
  out.addAll([0, 0, 12, 0, 1, 0x80, 0x01]);
  return out;
}

/// Best-effort on-link multicast. iOS/network policy may block multicast.
Future<List<LanProbeHost>> discoverLanNeighbors(
  String prefix, {
  Duration duration = const Duration(milliseconds: 1800),
}) async {
  if (!isPrivateIPv4('$prefix.1')) {
    throw const FormatException('Private /24 network required');
  }
  final devices = <String, LanProbeHost>{};
  final sockets = <RawDatagramSocket>[];
  final subscriptions = <StreamSubscription<RawSocketEvent>>[];
  try {
    final mdns = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final ssdp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sockets.addAll([mdns, ssdp]);
    subscriptions.add(mdns.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = mdns.receive()) != null) {
        final names = parseMdnsAddresses(packet!.data);
        for (final row in names.entries) {
          if (_onPrefix(row.key, prefix)) {
            devices[row.key] = LanProbeHost(row.key, row.value, 'mDNS');
          }
        }
      }
    }));
    subscriptions.add(ssdp.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = ssdp.receive()) != null) {
        final ip = packet!.address.address;
        if (!_onPrefix(ip, prefix)) continue;
        final item = parseSsdpHost(ip, packet.data);
        if (item != null) devices.putIfAbsent(ip, () => item);
      }
    }));
    try {
      mdns.send(_mdnsQuestion('_services._dns-sd._udp.local'),
          InternetAddress('224.0.0.251'), 5353);
      mdns.send(_mdnsQuestion('_workstation._tcp.local'),
          InternetAddress('224.0.0.251'), 5353);
    } on SocketException {
      // Some networks disallow multicast sends.
    }
    try {
      final request = ascii.encode('M-SEARCH * HTTP/1.1\\r\\n'
          'HOST: 239.255.255.250:1900\\r\\n'
          'MAN: "ssdp:discover"\\r\\n'
          'MX: 1\\r\\n'
          'ST: ssdp:all\\r\\n\\r\\n');
      ssdp.send(request, InternetAddress('239.255.255.250'), 1900);
    } on SocketException {
      // TCP and TapTether UDP discovery remain available.
    }
    await Future<void>.delayed(duration);
  } catch (_) {
    // Discovery must never make the regular TCP scan fail.
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    for (final socket in sockets) {
      socket.close();
    }
  }
  return devices.values.toList();
}
