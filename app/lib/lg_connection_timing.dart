import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'lg_webos_client.dart';

/// Persisted, device-scoped TV wake/recovery milestones. The certificate
/// fingerprint is used as the stable key if DHCP changes the IP address.
class LgConnectionTiming {
  const LgConnectionTiming({
    this.lastPoweredOnMs,
    this.findingStartedMs,
    this.foundDuringWakeMs,
    this.connectedDuringWakeMs,
    this.lastFoundMs,
    this.lastConnectedMs,
    this.lastPowerToFoundSeconds,
    this.lastPowerToConnectedSeconds,
  });

  final int? lastPoweredOnMs;
  final int? findingStartedMs;
  final int? foundDuringWakeMs;
  final int? connectedDuringWakeMs;
  final int? lastFoundMs;
  final int? lastConnectedMs;
  final int? lastPowerToFoundSeconds;
  final int? lastPowerToConnectedSeconds;

  static LgConnectionTiming fromJson(Map<String, dynamic> data) {
    int? number(String key) => (data[key] as num?)?.toInt();
    return LgConnectionTiming(
      lastPoweredOnMs: number('lastPoweredOnMs'),
      findingStartedMs: number('findingStartedMs'),
      foundDuringWakeMs: number('foundDuringWakeMs'),
      connectedDuringWakeMs: number('connectedDuringWakeMs'),
      lastFoundMs: number('lastFoundMs'),
      lastConnectedMs: number('lastConnectedMs'),
      lastPowerToFoundSeconds: number('lastPowerToFoundSeconds'),
      lastPowerToConnectedSeconds: number('lastPowerToConnectedSeconds'),
    );
  }

  Map<String, dynamic> toJson() => {
    'lastPoweredOnMs': lastPoweredOnMs,
    'findingStartedMs': findingStartedMs,
    'foundDuringWakeMs': foundDuringWakeMs,
    'connectedDuringWakeMs': connectedDuringWakeMs,
    'lastFoundMs': lastFoundMs,
    'lastConnectedMs': lastConnectedMs,
    'lastPowerToFoundSeconds': lastPowerToFoundSeconds,
    'lastPowerToConnectedSeconds': lastPowerToConnectedSeconds,
  };

  bool isActiveWake(DateTime now) {
    final start = lastPoweredOnMs;
    if (start == null || connectedDuringWakeMs != null) return false;
    final elapsed = now.millisecondsSinceEpoch - start;
    return elapsed >= 0 && elapsed < const Duration(minutes: 30).inMilliseconds;
  }

  bool hasRecentWake(DateTime now) {
    final start = lastPoweredOnMs;
    if (start == null) return false;
    final elapsed = now.millisecondsSinceEpoch - start;
    return elapsed >= 0 && elapsed < const Duration(hours: 2).inMilliseconds;
  }

  LgConnectionTiming powerOn(DateTime now) => LgConnectionTiming(
    lastPoweredOnMs: now.millisecondsSinceEpoch,
    lastFoundMs: lastFoundMs,
    lastConnectedMs: lastConnectedMs,
    lastPowerToFoundSeconds: lastPowerToFoundSeconds,
    lastPowerToConnectedSeconds: lastPowerToConnectedSeconds,
  );

  LgConnectionTiming finding(DateTime now) => LgConnectionTiming(
    lastPoweredOnMs: lastPoweredOnMs,
    findingStartedMs: findingStartedMs ?? now.millisecondsSinceEpoch,
    foundDuringWakeMs: foundDuringWakeMs,
    connectedDuringWakeMs: connectedDuringWakeMs,
    lastFoundMs: lastFoundMs,
    lastConnectedMs: lastConnectedMs,
    lastPowerToFoundSeconds: lastPowerToFoundSeconds,
    lastPowerToConnectedSeconds: lastPowerToConnectedSeconds,
  );

  LgConnectionTiming found(DateTime now) {
    final when = now.millisecondsSinceEpoch;
    final wake = isActiveWake(now) ? lastPoweredOnMs : null;
    final firstFound = foundDuringWakeMs ?? when;
    return LgConnectionTiming(
      lastPoweredOnMs: lastPoweredOnMs,
      findingStartedMs: findingStartedMs,
      foundDuringWakeMs: wake != null ? firstFound : foundDuringWakeMs,
      connectedDuringWakeMs: connectedDuringWakeMs,
      lastFoundMs: when,
      lastConnectedMs: lastConnectedMs,
      lastPowerToFoundSeconds: wake != null
          ? ((firstFound - wake) / 1000).round()
          : lastPowerToFoundSeconds,
      lastPowerToConnectedSeconds: lastPowerToConnectedSeconds,
    );
  }

  LgConnectionTiming connected(DateTime now) {
    final when = now.millisecondsSinceEpoch;
    final wake = isActiveWake(now) ? lastPoweredOnMs : null;
    final foundMs = foundDuringWakeMs ?? when;
    return LgConnectionTiming(
      lastPoweredOnMs: lastPoweredOnMs,
      findingStartedMs: findingStartedMs,
      foundDuringWakeMs: wake != null ? foundMs : foundDuringWakeMs,
      connectedDuringWakeMs: wake != null ? when : connectedDuringWakeMs,
      lastFoundMs: lastFoundMs ?? when,
      lastConnectedMs: when,
      lastPowerToFoundSeconds: wake != null
          ? ((foundMs - wake) / 1000).round()
          : lastPowerToFoundSeconds,
      lastPowerToConnectedSeconds: wake != null
          ? ((when - wake) / 1000).round()
          : lastPowerToConnectedSeconds,
    );
  }
}

/// Examples: 00:07, 02:35, 1:03:12.
String lgElapsed(Duration duration) {
  final total = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final seconds = (total % 60).toString().padLeft(2, '0');
  final minutes = ((total ~/ 60) % 60).toString().padLeft(2, '0');
  if (total < 3600) return '$minutes:$seconds';
  return '${total ~/ 3600}:$minutes:$seconds';
}

String lgClock(int? epochMs, {
  DateTime Function(int)? fromEpoch,
  DateTime? now,
}) {
  if (epochMs == null) return 'Never';
  final date = fromEpoch?.call(epochMs) ??
      DateTime.fromMillisecondsSinceEpoch(epochMs);
  final today = now ?? DateTime.now();
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final minute = date.minute.toString().padLeft(2, '0');
  final clock = '$hour:$minute ${date.hour < 12 ? "AM" : "PM"}';
  final eventDay = DateTime(date.year, date.month, date.day);
  final currentDay = DateTime(today.year, today.month, today.day);
  final dayDifference = currentDay.difference(eventDay).inDays;
  if (dayDifference == 0) return clock;
  if (dayDifference == 1) return 'Yesterday $clock';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final year = date.year != today.year ? ', ${date.year}' : '';
  return '${months[date.month - 1]} ${date.day}$year · $clock';
}

/// Asynchronous Keychain-backed storage shared by the foreground app and its
/// scheduled LG wake recovery. No pairing key or token is persisted here.
class LgConnectionTimingStore {
  LgConnectionTimingStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        );

  static const _key = 'taptether.lg.connection-timing.v1';
  final FlutterSecureStorage _storage;

  String identity(LgTvDevice tv) {
    if (tv.tlsPin.isNotEmpty) return 'pin:${tv.tlsPin.toUpperCase()}';
    if (tv.deviceUuid.isNotEmpty) return 'uuid:${tv.deviceUuid}';
    return 'host:${tv.host}';
  }

  Future<Map<String, dynamic>> _read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return {};
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<LgConnectionTiming> read(LgTvDevice tv) async {
    final record = (await _read())[identity(tv)];
    if (record is Map) {
      return LgConnectionTiming.fromJson(Map<String, dynamic>.from(record));
    }
    return const LgConnectionTiming();
  }

  Future<LgConnectionTiming> _update(LgTvDevice tv,
      LgConnectionTiming Function(LgConnectionTiming) update) async {
    final records = await _read();
    final id = identity(tv);
    final previous = records[id] is Map
        ? LgConnectionTiming.fromJson(
            Map<String, dynamic>.from(records[id] as Map))
        : const LgConnectionTiming();
    final next = update(previous);
    records[id] = next.toJson();
    await _storage.write(key: _key, value: jsonEncode(records));
    return next;
  }

  Future<LgConnectionTiming> powerOn(LgTvDevice tv, DateTime now) =>
      _update(tv, (record) => record.powerOn(now));

  Future<LgConnectionTiming> finding(LgTvDevice tv, DateTime now) =>
      _update(tv, (record) => record.finding(now));

  Future<LgConnectionTiming> found(LgTvDevice tv, DateTime now) =>
      _update(tv, (record) => record.found(now));

  Future<LgConnectionTiming> connected(LgTvDevice tv, DateTime now) =>
      _update(tv, (record) => record.connected(now));
}
