import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Optional LG cloud integration, completely separate from local pairing.
/// Personal token and enabled device selection live only in secure storage.
/// There are NO API calls without a user action.
class LgThinQDevice {
  const LgThinQDevice({
    required this.id,
    required this.name,
    required this.type,
    this.model = '',
  });

  final String id;
  final String name;
  final String type;
  final String model;

  LgThinQDevice renamed(String value) => LgThinQDevice(
    id: id, name: value, type: type, model: model,
  );

  /// ThinQ TV inventory is a read-only discovery hint, never a local pairing.
  bool get isTelevision {
    final category = type.toUpperCase();
    return category == 'DEVICE_TV' || category == 'TV' ||
        category == 'DEVICE_TELEVISION' ||
        category.contains('DEVICE_TV_');
  }

  bool get isAppliance => type.toUpperCase().contains('WASHER') ||
      type.toUpperCase().contains('DRYER') ||
      type.toUpperCase().contains('REFRIGERATOR') ||
      type.toUpperCase().contains('WASHTOWER') ||
      type.toUpperCase().contains('WASHCOMBO');

  Map<String, String> toJson() => {
    'id': id, 'name': name, 'type': type, 'model': model,
  };

  static LgThinQDevice? parse(Object? value) {
    if (value is! Map) return null;
    String field(Map data, String key) => data[key] is String
        ? (data[key] as String).trim() : '';
    final info = value['deviceInfo'] is Map
        ? value['deviceInfo'] as Map : value;
    final id = field(value, 'deviceId').isNotEmpty
        ? field(value, 'deviceId') : field(value, 'id');
    if (id.isEmpty || id.length > 180) return null;
    final type = field(info, 'deviceType').isNotEmpty
        ? field(info, 'deviceType') : field(value, 'deviceType');
    final alias = field(info, 'alias').isNotEmpty
        ? field(info, 'alias') : field(value, 'name');
    final model = field(info, 'modelName').isNotEmpty
        ? field(info, 'modelName') : field(value, 'modelName');
    return LgThinQDevice(
      id: id,
      name: alias.isEmpty ? 'LG appliance' : alias,
      type: type,
      model: model,
    );
  }

  static LgThinQDevice? fromSaved(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty || id.length > 180) return null;
    return LgThinQDevice(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : 'LG appliance',
      type: raw['type'] is String ? raw['type'] as String : '',
      model: raw['model'] is String ? raw['model'] as String : '',
    );
  }
}

List<LgThinQDevice> parseThinQDevices(Object? body) {
  final list = body is List ? body
      : body is Map ? (body['devices'] ?? body['items']) : null;
  if (list is! List) return const [];
  final devices = <String, LgThinQDevice>{};
  for (final item in list) {
    final parsed = LgThinQDevice.parse(item);
    if (parsed != null) devices[parsed.id] = parsed;
  }
  return devices.values.toList();
}

class LgThinQStorage {
  static const tokenKey = 'taptether.lg.thinq.pat.v1';
  static const countryKey = 'taptether.lg.thinq.country.v1';
  static const clientKey = 'taptether.lg.thinq.client-id.v1';
  static const devicesKey = 'taptether.lg.thinq.enabled.v1';
  static const aliasesKey = 'taptether.lg.thinq.local-names.v1';

  LgThinQStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        );

  final FlutterSecureStorage _storage;

  Future<String?> token() => _storage.read(key: tokenKey);

  /// User-initiated alert opt-in permits iOS Keychain access *after the
  /// first device unlock* for OS-scheduled checks while the phone is locked.
  /// The personal token stays in this device's Keychain, never synced.
  Future<void> enableBackgroundTokenAccess() async {
    final saved = await token();
    if (saved == null || saved.isEmpty) {
      throw StateError('Connect LG ThinQ before enabling alerts.');
    }
    // Background isolates need all ThinQ metadata after first unlock;
    // migrating only the PAT leaves cloud checks blocked on locked phones.
    for (final key in [
      tokenKey, countryKey, clientKey, devicesKey, aliasesKey,
    ]) {
      final value = await _storage.read(key: key);
      if (value == null) continue;
      await _storage.write(
        key: key, value: value,
        iOptions: const IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );
    }
  }
  Future<String> country() async =>
      await _storage.read(key: countryKey) ?? 'US';

  Future<void> configure(String personalToken, String country) async {
    if (personalToken.trim().length < 20) {
      throw const FormatException('Enter a valid ThinQ personal access token.');
    }
    if (!const {'US', 'CA', 'IN', 'AU', 'GB', 'DE'}
        .contains(country)) {
      throw const FormatException('Choose a supported region.');
    }
    await _storage.write(key: tokenKey, value: personalToken.trim());
    await _storage.write(key: countryKey, value: country);
  }

  Future<String> clientId() async {
    final existing = await _storage.read(key: clientKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final octets = List<int>.generate(16, (_) => random.nextInt(256));
    octets[6] = (octets[6] & 0x0f) | 0x40;
    octets[8] = (octets[8] & 0x3f) | 0x80;
    final hex = octets.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
    final value = '${hex.substring(0,8)}-${hex.substring(8,12)}-'
        '${hex.substring(12,16)}-${hex.substring(16,20)}-'
        '${hex.substring(20)}';
    await _storage.write(key: clientKey, value: value);
    return value;
  }

  /// Local-only display names. Never sent to LG or used as an identifier.
  Future<Map<String, String>> localNames() async {
    final raw = await _storage.read(key: aliasesKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return const {};
      final result = <String, String>{};
      for (final entry in value.entries) {
        if (entry.key is String && entry.value is String &&
            (entry.key as String).isNotEmpty &&
            (entry.value as String).trim().isNotEmpty) {
          result[entry.key as String] = entry.value as String;
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  Future<void> renameDevice(String id, String proposedName) async {
    final name = proposedName.trim();
    if (id.isEmpty || name.isEmpty || name.length > 50 ||
        name.contains(RegExp(r'[\x00-\x1F]'))) {
      throw const FormatException('Use a name between 1 and 50 characters.');
    }
    final names = <String, String>{...await localNames(), id: name};
    await _storage.write(key: aliasesKey, value: jsonEncode(names));
    final enabled = await enabledDevices();
    if (enabled.any((device) => device.id == id)) {
      final updated = enabled.map((device) => device.id == id
          ? device.renamed(name) : device).toList();
      await _storage.write(key: devicesKey, value:
          jsonEncode(updated.map((device) => device.toJson()).toList()));
    }
  }

  Future<List<LgThinQDevice>> enabledDevices() async {
    final raw = await _storage.read(key: devicesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is! List) return const [];
      final names = await localNames();
      return value.map(LgThinQDevice.fromSaved)
          .whereType<LgThinQDevice>()
          .map((device) => names.containsKey(device.id)
              ? device.renamed(names[device.id]!) : device).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setEnabled(LgThinQDevice device, bool enable) async {
    final saved = <LgThinQDevice>[...await enabledDevices()];
    saved.removeWhere((entry) => entry.id == device.id);
    if (enable) {
      final names = await localNames();
      saved.add(names.containsKey(device.id)
          ? device.renamed(names[device.id]!) : device);
    }
    await _storage.write(key: devicesKey,
        value: jsonEncode(saved.map((d) => d.toJson()).toList()));
  }

  Future<void> disconnect() async {
    await _storage.delete(key: tokenKey);
    await _storage.delete(key: devicesKey);
    await _storage.delete(key: aliasesKey);
    // Keep stable client ID, which is not a user credential.
  }
}

/// Public, published API identification key from LG's Apache-2.0 ThinQ SDK.
/// This is NOT the user's personal access token.
const lgThinQPublicApiKey = 'v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3';

String thinQRegion(String country) {
  if (const {'US','CA'}.contains(country)) return 'aic';
  if (const {'IN','AU'}.contains(country)) return 'kic';
  return 'eic';
}

class LgThinQClient {
  const LgThinQClient({
    required this.personalToken,
    required this.country,
    required this.clientId,
  });

  final String personalToken;
  final String country;
  final String clientId;

  Future<Object?> _get(String endpoint, {Map<String, String>? query}) async {
    final http = HttpClient();
    http.connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.https('api-${thinQRegion(country)}.lgthinq.com',
          '/$endpoint', query);
      final req = await http.getUrl(uri).timeout(const Duration(seconds: 10));
      req.headers.set('Authorization', 'Bearer $personalToken');
      req.headers.set('x-country', country);
      req.headers.set('x-client-id', clientId);
      req.headers.set('x-api-key', lgThinQPublicApiKey);
      req.headers.set('x-service-phase', 'OP');
      final random = Random.secure();
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      req.headers.set('x-message-id', base64UrlEncode(bytes)
          .replaceAll('=', ''));
      // The PAT is sent only to the fixed official LG regional host.
      req.followRedirects = false;
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.isRedirect) {
        await resp.drain<void>();
        throw StateError('ThinQ redirected unexpectedly; no credentials sent.');
      }
      final raw = await utf8.decoder.bind(resp).join()
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        throw StateError(resp.statusCode == 401 || resp.statusCode == 403
            ? 'ThinQ token is invalid or lacks permission for this device.'
            : 'ThinQ request failed (HTTP ${resp.statusCode}).');
      }
      final parsed = jsonDecode(raw);
      if (parsed is! Map || parsed.containsKey('error')) {
        throw StateError('ThinQ returned an error or unexpected response.');
      }
      return parsed['response'];
    } on HandshakeException {
      throw StateError('Could not verify LG ThinQ TLS certificate.');
    } finally {
      http.close(force: true);
    }
  }

  /// LG ThinQ conditional-control POST. Only invoke after validating an
  /// exact resource/property/value from this device's current profile.
  /// A 2xx response means LG accepted the request, not that hardware
  /// has finished the operation. Device state must be refreshed afterward.
  Future<void> control(String deviceId, Map<String, Object?> payload) async {
    if (payload.isEmpty || payload.length > 4) {
      throw const FormatException('Invalid ThinQ control request.');
    }
    final http = HttpClient();
    http.connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.https('api-${thinQRegion(country)}.lgthinq.com',
          '/devices/${Uri.encodeComponent(deviceId)}/control');
      final req = await http.postUrl(uri)
          .timeout(const Duration(seconds: 10));
      req.followRedirects = false;
      req.headers.set('Authorization', 'Bearer $personalToken');
      req.headers.set('x-country', country);
      req.headers.set('x-client-id', clientId);
      req.headers.set('x-api-key', lgThinQPublicApiKey);
      req.headers.set('x-service-phase', 'OP');
      req.headers.set('x-conditional-control', 'true');
      final random = Random.secure();
      req.headers.set('x-message-id', base64UrlEncode(
          List<int>.generate(16, (_) => random.nextInt(256)))
          .replaceAll('=', ''));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.isRedirect) {
        await resp.drain<void>();
        throw StateError('LG ThinQ redirected the control request.');
      }
      final responseBody = await utf8.decoder.bind(resp).join()
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw StateError('LG rejected control (HTTP ${resp.statusCode}).');
      }
      if (responseBody.isNotEmpty) {
        final decoded = jsonDecode(responseBody);
        if (decoded is Map && decoded['error'] != null) {
          final error = decoded['error'];
          final code = error is Map ? error['code'] : null;
          throw StateError('LG rejected command'
              '${code == null ? "" : " (code $code)"}.');
        }
      }
    } finally {
      http.close(force: true);
    }
  }

  Future<List<LgThinQDevice>> discover() async =>
      parseThinQDevices(await _get('devices'));

  /// Read-only ThinQ inventory used only for optional TV MAC discovery.
  /// The caller must filter it to a matching TV. This does not issue power
  /// commands or expose the account's other device details in the UI.
  Future<Object?> tvNetworkInventory() => _get('devices');

  Future<Object?> profile(String deviceId) async =>
      _get('devices/${Uri.encodeComponent(deviceId)}/profile');

  Future<Object?> state(String deviceId) async =>
      _get('devices/${Uri.encodeComponent(deviceId)}/state');

  /// Optional LG energy API. Availability depends on model and permissions.
  Future<Object?> energyProfile(String deviceId) =>
      _get('devices/energy/${Uri.encodeComponent(deviceId)}/profile');

  Future<Object?> energyUsage(String deviceId, String property,
      String period, String startDate, String endDate) async {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,60}$').hasMatch(property) ||
        !const {'DAILY', 'MONTHLY'}.contains(period)) {
      throw const FormatException('Invalid energy query.');
    }
    final length = period == 'DAILY' ? 8 : 6;
    if (startDate.length != length || endDate.length != length ||
        !RegExp(r'^\d+$').hasMatch(startDate) ||
        !RegExp(r'^\d+$').hasMatch(endDate)) {
      throw const FormatException('Invalid energy usage date.');
    }
    return _get('devices/energy/${Uri.encodeComponent(deviceId)}/usage',
        query: {
          'property': property,
          'period': period,
          'startDate': startDate,
          'endDate': endDate,
        });
  }
}

/// Filter LG response to common non-sensitive status/model properties.
/// Avoid exposing raw API payloads, identifiers, tokens or account details.
Map<String, String> safeThinQSummary(Object? data) {
  if (data is! Map) return const {};
  const allowed = <String>{
    'modelName', 'model', 'modelCode', 'deviceType', 'deviceState',
    'runState', 'operation', 'remainingTime', 'remainTime',
    'currentCourse', 'course', 'temperature', 'tempUnit',
    'refrigeratorTemp', 'freezerTemp', 'doorState', 'doorOpen',
    'filterLife', 'completionTime', 'washerOperationMode',
    'dryerOperationMode', 'washerDryerOperationMode',
  };
  final result = <String, String>{};
  void visit(Map object, int depth) {
    if (depth > 4 || result.length >= 24) return;
    for (final entry in object.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (allowed.contains(key) && value != null &&
          (value is String || value is num || value is bool)) {
        final text = value.toString();
        result[key] = text.length <= 90 ? text : text.substring(0, 90);
      } else if (value is Map) {
        visit(value, depth + 1);
      }
    }
  }
  visit(data, 0);
  return result;
}
