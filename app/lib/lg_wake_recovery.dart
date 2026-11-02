import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:workmanager/workmanager.dart';

import 'lan_scan.dart';
import 'lg_webos_client.dart';
import 'tv_network_status.dart';

const lgWakeRecoveryJob = 'com.taptether.taptether.lg-tv-wake';
const lgWakeRecoveryDelay = Duration(seconds: 10);
const lgWakeRecoveryWindow = Duration(minutes: 30);
const _pendingKey = 'taptether.lg.wake.pending.v1';

/// Recovers TV IP addresses after the user explicitly sends Wake-on-LAN.
/// Workmanager wakeups on iOS are opportunistic, never exact-time timers.
class LgWakeRecovery {
  LgWakeRecovery._();
  static final instance = LgWakeRecovery._();

  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  bool _running = false;

  Future<Map<String, int>> _pending() async {
    final raw = await _storage.read(key: _pendingKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, int>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(Map<String, int> pending) async {
    if (pending.isEmpty) {
      await _storage.delete(key: _pendingKey);
    } else {
      await _storage.write(key: _pendingKey, value: jsonEncode(pending));
    }
  }

  /// Save only the trusted fingerprint and expiry, not pairing secrets.
  Future<void> queue(LgTvDevice tv) async {
    if (tv.tlsPin.isEmpty || tv.clientKey.isEmpty) return;
    final pending = await _pending();
    pending[tv.tlsPin.toUpperCase()] =
        DateTime.now().millisecondsSinceEpoch +
            lgWakeRecoveryWindow.inMilliseconds;
    await _write(pending);
    await schedule();
  }

  Future<void> schedule() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    if ((await _pending()).isEmpty) return;
    await Workmanager().registerPeriodicTask(
      lgWakeRecoveryJob,
      lgWakeRecoveryJob,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  /// Check all saved IPs first and scan port 3001 only if a TV moved.
  /// Successful TLS and existing paired credentials are mandatory to
  /// update a saved address; an open port is never sufficient.
  Future<bool> check() async {
    if (_running) return false;
    _running = true;
    try {
      final pending = await _pending();
      if (pending.isEmpty) return false;
      final now = DateTime.now().millisecondsSinceEpoch;
      pending.removeWhere((_, until) => until <= now);
      if (pending.isEmpty) {
        await _write(pending);
        await Workmanager().cancelByUniqueName(lgWakeRecoveryJob);
        return false;
      }
      final network = await detectLanRange();
      if (network == null) return false;
      final saved = await LgTvStore().read();
      var recoveredAny = false;
      // The old IP usually remains valid; it is much faster to verify it.
      for (final tv in saved) {
        final key = tv.tlsPin.toUpperCase();
        if (!pending.containsKey(key)) continue;
        if (lanRangeContains(network, tv.host) &&
            await matchesLgTlsPin(tv.host, tv.tlsPin)) {
          pending.remove(key);
          recoveredAny = true;
        }
      }
      for (final tv in saved) {
        final key = tv.tlsPin.toUpperCase();
        if (!pending.containsKey(key)) continue;
        final recovered = await relocateLgTv(tv);
        if (recovered != null) {
          pending.remove(key);
          recoveredAny = true;
        }
      }
      await _write(pending);
      if (pending.isEmpty) {
        await Workmanager().cancelByUniqueName(lgWakeRecoveryJob);
      }
      return recoveredAny;
    } finally {
      _running = false;
    }
  }
}
