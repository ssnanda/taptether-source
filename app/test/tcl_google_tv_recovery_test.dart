import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/tcl_google_tv_recovery.dart';
import 'package:taptether/tcl_google_tv_store.dart';

class _MemoryTclStore extends TclGoogleTvStore {
  _MemoryTclStore(this.saved);
  final List<TclGoogleTv> saved;

  @override
  Future<TclGoogleTv?> relocate(
      TclGoogleTv expected, String candidateHost) async {
    final i = saved.indexWhere((tv) => tv.host == expected.host &&
        tv.serverFingerprint == expected.serverFingerprint &&
        tv.certificatePem == expected.certificatePem &&
        tv.privateKeyPem == expected.privateKeyPem);
    if (i < 0 || saved.any((tv) => tv.host == candidateHost)) return null;
    final moved = saved[i].copyWith(host: candidateHost);
    saved[i] = moved;
    return moved;
  }
}

void main() {
  const tv = TclGoogleTv(
      host: '192.168.1.113', name: 'TCL Living Room',
      certificatePem: 'SAVED-CERT', privateKeyPem: 'SAVED-KEY',
      serverFingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  final lan = rangeFromWifi('192.168.1.4', '255.255.255.0')!;

  test('finds changed TV IP only after its saved identity verifies', () async {
    final store = _MemoryTclStore([tv]);
    final moved = await relocateTclGoogleTv(
      tv, network: lan, store: store,
      portReachable: (host) async =>
          host == '192.168.1.150' || host == '192.168.1.175',
      verifyPairing: (candidate) async =>
          candidate.host == '192.168.1.175' &&
          candidate.serverFingerprint == tv.serverFingerprint &&
          candidate.certificatePem == tv.certificatePem,
    );
    expect(moved?.host, '192.168.1.175');
    expect(moved?.privateKeyPem, tv.privateKeyPem);
    expect(moved?.certificatePem, tv.certificatePem);
    expect(store.saved.single.host, '192.168.1.175');
    expect(store.saved.single.name, 'TCL Living Room');
  });

  test('port-only match cannot rewrite a saved device', () async {
    final store = _MemoryTclStore([tv]);
    final match = await relocateTclGoogleTv(
      tv, network: lan, store: store,
      portReachable: (host) async => host == '192.168.1.200',
      verifyPairing: (_) async => false,
    );
    expect(match, isNull);
    expect(store.saved.single.host, '192.168.1.113');
  });

  test('unpaired TV is never scanned or relocated', () async {
    final store = _MemoryTclStore([
      const TclGoogleTv(host: '192.168.1.113', name: 'Unpaired'),
    ]);
    var probed = false;
    final found = await relocateTclGoogleTv(
      store.saved.single, network: lan, store: store,
      portReachable: (_) async {
        probed = true;
        return true;
      },
    );
    expect(found, isNull);
    expect(probed, isFalse);
  });
}
