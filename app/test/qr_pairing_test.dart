import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/qr_pairing.dart';

void main() {
  test('QR pairing requires explicit LAN address and pinned fingerprint', () {
    final fingerprint = List.filled(64, 'A').join();
    final valid = 'taptether://pair?v=1&host=192.168.68.87&token='
        'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234'
        '&fingerprint=NaN';
    final pairing = PairingQR.parse(valid);
    expect(pairing, isNotNull);
    expect(pairing!.host, '192.168.68.87');
    expect(PairingQR.parse(valid.replaceFirst('192.168.68.87', '8.8.8.8')), isNull);
    expect(PairingQR.parse(valid.replaceFirst('taptether://', 'https://')), isNull);
    expect(PairingQR.parse(valid.replaceFirst(fingerprint, 'AAAAAAAAAA')), isNull);
  });
}
