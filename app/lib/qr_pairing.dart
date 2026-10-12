import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class PairingQR {
  const PairingQR(this.host, this.token, this.fingerprint);

  final String host;
  final String token;
  final String fingerprint;

  static PairingQR? parse(String? raw) {
    if (raw == null || raw.length > 512) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'taptether' || uri.host != 'pair' ||
        uri.queryParameters['v'] != '1') {
      return null;
    }
    final host = uri.queryParameters['host'] ?? '';
    final token = uri.queryParameters['token'] ?? '';
    final fingerprint =
        (uri.queryParameters['fingerprint'] ?? '').toUpperCase();
    final validIP = RegExp(r'^(10|192|172)\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$');
    if (!validIP.hasMatch(host) || token.length < 20 ||
        !RegExp(r'^[0-9A-F]{64}$').hasMatch(fingerprint)) {
      return null;
    }
    final octets = host.split('.').map(int.parse).toList();
    if (octets.any((v) => v < 0 || v > 255) ||
        !(octets[0] == 10 || (octets[0] == 172 &&
            octets[1] >= 16 && octets[1] <= 31) ||
            (octets[0] == 192 && octets[1] == 168))) {
      return null;
    }
    return PairingQR(host, token, fingerprint);
  }
}

class PairingScanner extends StatefulWidget {
  const PairingScanner({super.key});

  @override
  State<PairingScanner> createState() => _PairingScannerState();
}

class _PairingScannerState extends State<PairingScanner> {
  bool _found = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan computer pairing QR')),
    body: Column(children: [
      const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Scan only a QR shown on your own computer or SSH terminal. '
            'Pairing codes contain private credentials.'),
      ),
      Expanded(child: MobileScanner(
        onDetect: (capture) {
          if (_found) return;
          for (final barcode in capture.barcodes) {
            final pairing = PairingQR.parse(barcode.rawValue);
            if (pairing == null) continue;
            _found = true;
            Navigator.of(context).pop(pairing);
            return;
          }
        },
      )),
    ]),
  );
}
