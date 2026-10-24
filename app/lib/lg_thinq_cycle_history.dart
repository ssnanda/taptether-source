import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'lg_thinq_features.dart';

/// Only cycles observed by TapTether while the appliance is being refreshed.
/// Does not reconstruct LG's historical cycle log from a cumulative counter.
class ThinQCycleEntry {
  const ThinQCycleEntry({
    required this.startedAt,
    required this.lastSeenAt,
    required this.lastState,
    required this.outcome,
    required this.samples,
    this.endedAt,
    this.initialCount,
    this.lastCount,
    this.initialTotalMinutes,
    this.lastRemainingMinutes,
  });

  final DateTime startedAt;
  final DateTime lastSeenAt;
  final DateTime? endedAt;
  final String lastState;
  final String outcome; // observing, finished, or stopped/unknown
  final int samples;
  final int? initialCount;
  final int? lastCount;
  final int? initialTotalMinutes;
  final int? lastRemainingMinutes;

  bool get active => outcome == 'observing';

  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toIso8601String(),
    'lastSeenAt': lastSeenAt.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'lastState': lastState,
    'outcome': outcome,
    'samples': samples,
    'initialCount': initialCount,
    'lastCount': lastCount,
    'initialTotalMinutes': initialTotalMinutes,
    'lastRemainingMinutes': lastRemainingMinutes,
  };

  static ThinQCycleEntry? fromJson(Object? source) {
    if (source is! Map) return null;
    final start = DateTime.tryParse(source['startedAt']?.toString() ?? '');
    final last = DateTime.tryParse(source['lastSeenAt']?.toString() ?? '');
    if (start == null || last == null) return null;
    final end = DateTime.tryParse(source['endedAt']?.toString() ?? '');
    return ThinQCycleEntry(
      startedAt: start,
      lastSeenAt: last,
      endedAt: end,
      lastState: source['lastState']?.toString() ?? '',
      outcome: source['outcome']?.toString() ?? 'stopped/unknown',
      samples: source['samples'] is int ? source['samples'] as int : 1,
      initialCount: source['initialCount'] as int?,
      lastCount: source['lastCount'] as int?,
      initialTotalMinutes: source['initialTotalMinutes'] as int?,
      lastRemainingMinutes: source['lastRemainingMinutes'] as int?,
    );
  }
}

String? thinQState(List<ThinQFeature> features) {
  for (final f in features) {
    if (f.property == 'currentState' && f.current is String) {
      return (f.current as String).toUpperCase();
    }
  }
  return null;
}

int? thinQInteger(List<ThinQFeature> features, String name) {
  for (final f in features) {
    if (f.property != name) continue;
    final value = f.current;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
  }
  return null;
}

int? thinQMinutes(List<ThinQFeature> features,
    String hourField, String minuteField) {
  final hours = thinQInteger(features, hourField);
  final minutes = thinQInteger(features, minuteField);
  if (hours == null && minutes == null) return null;
  return (hours ?? 0) * 60 + (minutes ?? 0);
}

bool thinQIsRunning(String? state) {
  if (state == null) return false;
  const notRunning = {
    'POWER_OFF', 'OFF', 'END', 'DONE', 'COMPLETE', 'COMPLETED',
    'STANDBY', 'READY', 'PAUSE', 'PAUSED', 'ERROR', 'STOP',
    'STOPPED', 'IDLE', 'INITIAL', 'DELAY', 'DELAY_WASH',
    'RESERVATION',
  };
  return !notRunning.contains(state) &&
      (state.contains('WASH') || state.contains('RINS') ||
       state.contains('SPIN') || state.contains('DRY') ||
       state.contains('RUN') || state.contains('SENS') ||
       state.contains('SOAK') || state.contains('STEAM'));
}

bool thinQIsFinished(String? state) {
  return const {'END', 'DONE', 'COMPLETE', 'COMPLETED'}
      .contains(state);
}

/// The caller passes only a successful fresh API state, never cached state.
List<ThinQCycleEntry> observeThinQCycle(
    List<ThinQCycleEntry> old,
    List<ThinQFeature> features,
    DateTime now) {
  final state = thinQState(features);
  if (state == null) return old;
  final running = thinQIsRunning(state);
  final last = old.isEmpty ? null : old.first;
  final count = thinQInteger(features, 'cycleCount');
  final remain = thinQMinutes(features, 'remainHour', 'remainMinute');
  final total = thinQMinutes(features, 'totalHour', 'totalMinute');

  if (running && (last == null || !last.active)) {
    final fresh = ThinQCycleEntry(
      startedAt: now, lastSeenAt: now, lastState: state,
      outcome: 'observing', samples: 1,
      initialCount: count, lastCount: count,
      initialTotalMinutes: total, lastRemainingMinutes: remain,
    );
    return [fresh, ...old].take(80).toList();
  }
  if (last == null || !last.active) return old;
  // If the screen was closed between samples, retain a cautious outcome.
  // A missed END event is not proof the cycle completed successfully.
  final outcome = running ? 'observing'
      : thinQIsFinished(state) ? 'finished' : 'stopped/unknown';
  final updated = ThinQCycleEntry(
    startedAt: last.startedAt, lastSeenAt: now,
    endedAt: running ? null : now, lastState: state,
    outcome: outcome, samples: last.samples + 1,
    initialCount: last.initialCount, lastCount: count ?? last.lastCount,
    initialTotalMinutes: last.initialTotalMinutes ?? total,
    lastRemainingMinutes: remain,
  );
  return [updated, ...old.skip(1)].take(80).toList();
}

/// Phone-private cycle history. It does not sync to LG or backfill cycles.
class ThinQCycleHistoryStore {
  ThinQCycleHistoryStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String deviceId) =>
      'taptether.thinq.cycles.v1.${sha256.convert(utf8.encode(deviceId))}';

  Future<List<ThinQCycleEntry>> read(String deviceId) async {
    try {
      final raw = await _storage.read(key: _key(deviceId));
      if (raw == null) return [];
      final parsed = jsonDecode(raw);
      if (parsed is! List) return [];
      return parsed.map(ThinQCycleEntry.fromJson)
          .whereType<ThinQCycleEntry>().take(80).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<ThinQCycleEntry>> record(
      String deviceId, List<ThinQFeature> features, DateTime now) async {
    final updated = observeThinQCycle(await read(deviceId), features, now);
    await _storage.write(
      key: _key(deviceId),
      value: jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    return updated;
  }

  Future<void> clear(String deviceId) =>
      _storage.delete(key: _key(deviceId));
}
