import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/tcl_google_tv_store.dart';

void main() {
  test('TCL Google TV uses local addresses only', () {
    for (final address in ['192.168.1.79', '192.168.68.85',
        '10.0.118.42', '172.16.0.5', '172.31.0.8']) {
      expect(validTclGoogleTvHost(address), isTrue);
    }
    for (final address in ['76.244.19.112', '8.8.8.8', 'localhost',
        '192.168.1.0', '192.168.1.255', '192.168.1.999',
        'http://192.168.1.2', '192.168.1.2:6466']) {
      expect(validTclGoogleTvHost(address), isFalse);
    }
  });

  test('saved paired TV roundtrips certificate, identity and IP', () {
    const entry = TclGoogleTv(host: '192.168.1.45', name: 'Living Room TCL',
        certificatePem: 'CERT', privateKeyPem: 'KEY',
        serverFingerprint: 'aabbccddeeff00112233445566778899'
            'aabbccddeeff00112233445566778899');
    expect(entry.paired, isTrue);
    final recovered = TclGoogleTv.fromJson(entry.toJson());
    expect(recovered.paired, isTrue);
    expect(recovered.name, 'Living Room TCL');
    expect(recovered.privateKeyPem, 'KEY');
    expect(recovered.serverFingerprint.length, 64);
    expect(recovered.preferTouchpad, isFalse);
    final touchpad = recovered.copyWith(preferTouchpad: true);
    expect(TclGoogleTv.fromJson(touchpad.toJson()).preferTouchpad, isTrue);
    expect(TclGoogleTv.fromJson(touchpad.toJson()).privateKeyPem, 'KEY');
  });

  test('saved unpaired TV stays saved without a connection', () {
    final unpaired = TclGoogleTv.fromJson(const {
      'host': '192.168.21.35',
      'name': 'Bedroom TCL',
    });
    expect(unpaired.name, 'Bedroom TCL');
    expect(unpaired.paired, isFalse);
    expect(unpaired.toJson()['host'], '192.168.21.35');
  });
}
