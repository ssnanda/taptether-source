import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/mag254_protocol.dart';
import 'package:taptether/mag254_store.dart';

void main() {
  test('MAG crypto matches independently captured MAGic Remote vector', () {
    const plain = '{"dev_id":"faeac9ec41c2f652"}';
    final encrypted = Mag254Protocol.crypt('259518', utf8.encode(plain),
        encrypt: true);
    expect(encrypted.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
        '584dcfb57fdb720247026fb7e904a27d'
        '14ee65560f1d6f6efca85f3c0b');
    final decrypted = Mag254Protocol.crypt('259518', encrypted,
        encrypt: false);
    expect(utf8.decode(decrypted), plain);
  });

  test('MAG command framing accepts split packets and multiple frames', () {
    final id = 'faeac9ec41c2f652';
    final packet = Mag254Protocol.requestPair(id);
    expect(packet[4], packet.length);
    expect(utf8.decode(packet.sublist(6, 38)),
        'pairing-reqpairing-reqpairing-re');
    final parser = Mag254Frames();
    expect(parser.feed(packet.sublist(0, 12)), isEmpty);
    final remaining = parser.feed([...packet.sublist(12), ...packet]);
    expect(remaining.length, 2);
    expect(remaining.first, packet);
    expect(remaining.last, packet);
  });

  test('MAG remote codes match manufacturer-compatible remote', () {
    expect(Mag254Keys.up, 189);
    expect(Mag254Keys.ok, 172);
    expect(Mag254Keys.power, 140);
    expect(Mag254Keys.digit(0), 128);
    expect(Mag254Keys.digit(9), 137);
    expect(() => Mag254Keys.digit(10), throwsRangeError);
  });

  test('MAG pairing codes are independent of optional device password', () {
    final saved = Mag254Device.fromJson({
      'host': '192.168.1.80',
      'name': 'Office MAG',
      'deviceId': 'faeac9ec41c2f652',
      'pairingCode': '259518',
    });
    expect(saved.paired, isTrue);
    final result = Mag254Device.fromJson(saved.toJson());
    expect(result.paired, isTrue);
    expect(result.name, 'Office MAG');
    expect(result.pairingCode, '259518');
    final offline = result.copyWith(pairingCode: '');
    expect(offline.paired, isFalse);
  });
}
