import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/xbox_smartglass.dart';

List<int> _sgString(String value) {
  final bytes = utf8.encode(value);
  return [bytes.length >> 8, bytes.length & 255, ...bytes, 0];
}

List<int> _response({String name = 'Family Xbox', String uuid = 'xbox-uuid'}) {
  // Small synthetic certificate-shaped fixture with issuer CN and Subject CN.
  final cert = List<int>.filled(96, 0);
  cert[0] = 0x30;
  cert[1] = 94;
  const issuer = 'XBL Smart Glass Issuing CA';
  const liveId = 'FD12345678901234';
  final issuerCn = [6, 3, 0x55, 4, 3, 0x0c,
    issuer.length, ...issuer.codeUnits];
  final subjectCn = [6, 3, 0x55, 4, 3, 0x0c,
    liveId.length, ...liveId.codeUnits];
  cert.setRange(3, 3 + issuerCn.length, issuerCn);
  cert.setRange(50, 50 + subjectCn.length, subjectCn);
  final body = <int>[
    0, 0, 0, 4, // allow anonymous discovery
    0, 1, // Xbox One family
    0, 0, // reserved
    ..._sgString(name),
    ..._sgString(uuid),
    0, 0, 0, 0, // last error
    cert.length >> 8, cert.length & 255,
    ...cert,
  ];
  return [0xdd, 1, body.length >> 8, body.length & 255, 0, 0, ...body];
}

void main() {
  test('discovery request uses documented version and iPhone type', () {
    expect(xboxDiscoveryPacket(), [
      0xdd, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 2,
    ]);
  });

  test('parses local Xbox discovery with stable ID and certificate pin', () {
    final xbox = parseXboxDiscovery(_response(), '192.168.68.122');
    expect(xbox, isNotNull);
    expect(xbox!.name, 'Family Xbox');
    expect(xbox.uuid, 'xbox-uuid');
    expect(xbox.liveId, 'FD12345678901234');
    expect(xbox.certificateSha256.length, 64);
    expect(xbox.copyWith(host: '192.168.68.123').uuid, xbox.uuid);
  });

  test('rejects spoofable/malformed packet shapes and public networks', () {
    final valid = _response();
    expect(parseXboxDiscovery(valid, '8.8.8.8'), isNull);
    expect(parseXboxDiscovery(valid.sublist(0, valid.length - 4),
        '192.168.68.122'), isNull);
    expect(parseXboxDiscovery([0xdd, 2, ...valid.skip(2)],
        '192.168.68.122'), isNull);
    final certificatePending = [...valid]..[9] = 8;
    expect(parseXboxDiscovery(certificatePending, '192.168.68.122'), isNull);
  });

  test('standby wake packet includes exact Live ID and no account data', () {
    final packet = xboxWakePacket('FD12345678901234');
    expect(packet.take(6), [0xdd, 2, 0, 19, 0, 2]);
    expect(packet.sublist(8, packet.length - 1),
        utf8.encode('FD12345678901234'));
    expect(packet.last, 0);
    expect(() => xboxWakePacket(''), throwsFormatException);
  });

  test('save model serializes only bounded metadata, not credentials', () {
    final xbox = parseXboxDiscovery(_response(), '192.168.68.122')!;
    final stored = XboxConsole.fromJson(xbox.toJson());
    expect(stored.uuid, xbox.uuid);
    expect(stored.certificateSha256, xbox.certificateSha256);
    expect(stored.toJson().containsKey('certificateDer'), isFalse);
    expect(stored.location, 'other');
  });
}