import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Local-only, bounded discovery history. No credentials or discovered
/// third-party IP addresses are written to this log.
class DeviceLocationLog {
  DeviceLocationLog._();
  static final instance = DeviceLocationLog._();

  static const maxEvents = 24;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  Future<void> _pending = Future<void>.value();

  static String storageKey(String deviceKey) =>
      'taptether.locate.history.v1.${sha256.convert(utf8.encode(deviceKey))}';

  static String safeMessage(String value) {
    // Diagnostics must not accidentally persist secrets or arbitrary errors.
    final short = value.replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    return short.length <= 150 ? short : short.substring(0, 150);
  }

  Future<void> record(String deviceKey, String event) {
    final result = _pending.catchError((Object _) {}).then((_) async {
      if (deviceKey.isEmpty) return;
      final key = storageKey(deviceKey);
      final previous = await _storage.read(key: key);
      final events = parse(previous);
      events.add('${DateTime.now().toUtc().toIso8601String()} · '
          '${safeMessage(event)}');
      await _storage.write(
          key: key,
          value: jsonEncode(events.length <= maxEvents
              ? events : events.sublist(events.length - maxEvents)));
    });
    _pending = result;
    return result;
  }

  Future<List<String>> read(String deviceKey) async {
    await _pending.catchError((Object _) {});
    if (deviceKey.isEmpty) return const [];
    return parse(await _storage.read(key: storageKey(deviceKey))).reversed.toList();
  }

  static List<String> parse(String? stored) {
    if (stored == null || stored.isEmpty) return <String>[];
    try {
      final entries = jsonDecode(stored);
      if (entries is List) {
        return entries.whereType<String>()
            .map(safeMessageWithTimestamp)
            .toList().take(maxEvents).toList();
      }
    } catch (_) {}
    return <String>[];
  }

  static String safeMessageWithTimestamp(String item) {
    return item.length <= 210 ? item : item.substring(0, 210);
  }
}
