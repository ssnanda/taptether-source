import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lan_scan.dart';

/// Explicit read-only SSDP appliance discovery; not the regular computer scan.
/// SSDP responses are untrusted hints and never authorize commands or pairing.
class LgLanClue {
  const LgLanClue({
    required this.ip,
    required this.name,
    required this.model,
    required this.server,
    required this.service,
  });

  final String ip;
  final String name;
  final String model;
  final String server;
  final String service;
}

/// Reject control characters, secret-looking headers and oversized metadata.
String safeApplianceLabel(String raw, {int max = 110}) {
  final trimmed = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
  return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
}

Map<String, String> parseSsdpHeaders(String response) {
  final result = <String, String>{};
  for (final line in const LineSplitter().convert(response)) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final name = line.substring(0, separator).trim().toLowerCase();
    if (!const {'server', 'st', 'usn', 'model', 'modelname',
      'friendlyname', 'x-friendly-name', 'x-model-name'}
        .contains(name)) continue;
    result[name] = safeApplianceLabel(line.substring(separator + 1));
  }
  return result;
}

LgLanClue? applianceFromSsdp(
    String senderIp, String response, DetectedLanRange network) {
  if (!lanRangeContains(network, senderIp)) return null;
  final headers = parseSsdpHeaders(response);
  final material = headers.values.join(' ').toLowerCase();
  // Only report LG/LGE identifiers. A generic UPnP device is not an LG
  // appliance, and a TV should not be guessed to be a washer.
  if (!(material.contains('lge') || material.contains('lg ') ||
        material.contains('lg-') || material.contains('lg_') ||
        material.contains('lg.com') || material.contains('lg electronics'))) {
    return null;
  }
  final model = headers['modelname'] ?? headers['x-model-name'] ??
      headers['model'] ?? '';
  final name = headers['friendlyname'] ?? headers['x-friendly-name'] ??
      'Possible LG device';
  return LgLanClue(
    ip: senderIp,
    name: name,
    model: model,
    server: headers['server'] ?? '',
    service: headers['st'] ?? '',
  );
}

class LgApplianceLanDiscovery {
  /// Sends only an SSDP M-SEARCH multicast and listens to its responses.
  /// No credential guessing, broadcast control, port sweep or cloud request.
  Future<List<LgLanClue>> scan(DetectedLanRange network) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
        reuseAddress: true);
    final devices = <String, LgLanClue>{};
    final done = Completer<void>();
    final stream = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final packet = datagram!;
        final hint = applianceFromSsdp(packet.address.address,
            utf8.decode(packet.data, allowMalformed: true), network);
        if (hint != null) devices[hint.ip] = hint;
      }
    }, onError: (_) {});
    try {
      final data = ascii.encode('M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: ssdp:all\r\n\r\n');
      socket.send(data, InternetAddress('239.255.255.250'), 1900);
      await Future.any<void>([
        Future<void>.delayed(const Duration(seconds: 4)),
        done.future,
      ]);
      return devices.values.toList()
        ..sort((a, b) => a.ip.compareTo(b.ip));
    } finally {
      await stream.cancel();
      socket.close();
    }
  }
}

/// Safe diagnostic text for explicit user review and copying. No credentials,
/// serial numbers, pairing identities, token, or raw network responses.
String lgLanDiagnostic(DetectedLanRange network, List<LgLanClue> clues) {
  final buffer = StringBuffer()
    ..writeln('TapTether LG appliance local discovery')
    ..writeln('Wi-Fi subnet: ${network.cidr}')
    ..writeln('Discovery: SSDP only; LG identity/model NOT verified')
    ..writeln('Matching advertisements: ${clues.length}');
  for (final item in clues) {
    buffer
      ..writeln('---')
      ..writeln('IP: ${item.ip}')
      ..writeln('Name hint: ${item.name}')
      ..writeln('Model hint: ${item.model.isEmpty ? 'Not advertised' : item.model}')
      ..writeln('Server hint: ${item.server}')
      ..writeln('Service hint: ${item.service}');
  }
  buffer.writeln('No result does not mean the appliance is offline.');
  return buffer.toString();
}
