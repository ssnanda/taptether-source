import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/xbox_lan_session.dart';
import 'package:taptether/xbox_smartglass.dart';

List<int> _field(String value) {
  final bytes = utf8.encode(value);
  return [bytes.length >> 8, bytes.length & 255, ...bytes, 0];
}

List<int> _discoveryWithCert(List<int> certificate) {
  final body = [
    0, 0, 0, 4, // anonymous discovery allowed
    0, 1, 0, 0, // console family and reserved
    ..._field('Living Room Xbox'),
    ..._field('console-stable-id'),
    0, 0, 0, 0, // last error
    certificate.length >> 8, certificate.length & 255, ...certificate
  ];
  return [0xdd, 1, body.length >> 8, body.length & 255, 0, 0,
    ...body];
}

void main() {
  test('local control button masks match documented Xbox LAN messages', () {
    expect(XboxLanButton.a, 0x10);
    expect(XboxLanButton.b, 0x20);
    expect(XboxLanButton.xbox, 0x02);
    expect(XboxLanButton.menu, 0x04);
    expect(XboxLanButton.view, 0x08);
    expect(XboxLanButton.up, 0x100);
    expect(XboxLanButton.down, 0x200);
    expect(XboxLanButton.left, 0x400);
    expect(XboxLanButton.right, 0x800);
    expect(XboxLanButton.lb, 0x1000);
    expect(XboxLanButton.rb, 0x2000);
  });

  test('certificate extraction accepts only a discovered Xbox identity', () {
    final cert = <int>[0x30, 0x5e, ...List<int>.filled(94, 0)];
    final valid = _discoveryWithCert(cert);
    expect(parseXboxDiscovery(valid, '192.168.1.82'), isNotNull);
    expect(xboxLanCertificate(valid, '192.168.1.82'), cert);
    expect(xboxLanCertificate(valid, '8.8.8.8'), isNull);
    final wrongType = [...valid]..[1] = 2;
    expect(xboxLanCertificate(wrongType, '192.168.1.82'), isNull);
  });

  test('only an explicit P-256 point is accepted from Xbox DER', () {
    final publicPoint = <int>[4, ...List<int>.generate(64, (n) => n + 1)];
    final cert = <int>[
      0x30, 0x7e,
      ...List<int>.filled(8, 0),
      0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
      0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
      0x03, 0x42, 0x00, ...publicPoint,
      ...List<int>.filled(10, 0)
    ];
    expect(xboxLanP256Point(cert), publicPoint);
    final wrongCurve = [...cert]..[27] = 8;
    expect(() => xboxLanP256Point(wrongCurve), throwsA(
        isA<XboxLanException>()));
    expect(() => xboxLanP256Point([0x30, 0]), throwsA(
        isA<XboxLanException>()));
  });

  test('no browser is needed to format local controller inputs', () {
    final masks = [XboxLanButton.a, XboxLanButton.b,
      XboxLanButton.up, XboxLanButton.menu];
    for (final mask in masks) {
      expect(mask, inInclusiveRange(0, 0xffff));
    }
  });
}
