import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Honeywell Home / Resideo v2 thermostat payload. Device IDs and location
/// IDs are strings because Resideo Connect supports UUID / large numeric IDs.
class ResideoDevice {
  const ResideoDevice({
    required this.id,
    required this.locationId,
    required this.location,
    required this.name,
    required this.system,
    required this.fan,
    required this.systemModes,
    required this.fanModes,
    required this.values,
    required this.unit,
    this.temperature,
    this.heat,
    this.cool,
    this.minHeat,
    this.maxHeat,
    this.minCool,
    this.maxCool,
    this.online = true,
  });

  final String id, locationId, location, name, system, fan, unit;
  final List<String> systemModes, fanModes;
  final Map<String, dynamic> values;
  final double? temperature, heat, cool, minHeat, maxHeat, minCool, maxCool;
  final bool online;

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.map((k, v) => MapEntry(k.toString(), v)) : {};
  static double? _number(Object? v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
  static List<String> _modes(Object? v) =>
      v is List ? v.whereType<String>().toList() : [];

  static ResideoDevice? fromApi(
      Object? item, String locationId, String location) {
    final raw = _map(item);
    final id = raw['deviceID']?.toString() ?? '';
    if (id.isEmpty || id.length > 180) return null;
    final kind = (raw['deviceClass'] ?? raw['deviceType'])
        ?.toString().toLowerCase();
    if (kind != null && kind.isNotEmpty && !kind.contains('thermostat')) {
      return null;
    }
    final settings = _map(raw['settings']);
    final fanSettings = _map(settings['fan']);
    final fanChange = _map(fanSettings['changeableValues']);
    final changeable = _map(raw['changeableValues']);
    return ResideoDevice(
      id: id,
      locationId: locationId,
      location: location,
      name: (raw['userDefinedDeviceName'] ?? raw['name'] ?? 'Thermostat')
          .toString(),
      // heatCoolMode is not the actual selected system switch position.
      system: (changeable['mode'] ?? 'Unknown').toString(),
      fan: (fanChange['mode'] ?? 'Unknown').toString(),
      systemModes: _modes(raw['allowedModes']),
      fanModes: _modes(fanSettings['allowedModes']),
      values: changeable,
      unit: (raw['units'] ?? 'Fahrenheit').toString(),
      temperature: _number(raw['indoorTemperature']),
      heat: _number(changeable['heatSetpoint']),
      cool: _number(changeable['coolSetpoint']),
      minHeat: _number(raw['minHeatSetpoint']),
      maxHeat: _number(raw['maxHeatSetpoint']),
      minCool: _number(raw['minCoolSetpoint']),
      maxCool: _number(raw['maxCoolSetpoint']),
      online: raw['isAlive'] != false,
    );
  }

  String get temperatureUnit => unit.toLowerCase().contains('celsius')
      ? '°C' : '°F';
  double get increment => temperatureUnit == '°C' ? .5 : 1;
  String display(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(value % 1 == 0 ? 0 : 1)}$temperatureUnit';

  /// Preserve all existing setpoints and supported auto-changeover state,
  /// avoiding unintended schedule and setpoint resets when switching modes.
  Map<String, Object?> systemPayload(String target,
      {double? heatTarget, double? coolTarget}) {
    final allowed = systemModes.map((v) => v.toLowerCase()).toSet();
    if (!allowed.contains(target.toLowerCase())) {
      throw const FormatException('System mode is not supported by the device.');
    }
    final payload = <String, Object?>{'mode': target};
    if (heatTarget ?? heat case final double value) {
      payload['heatSetpoint'] = value;
    }
    if (coolTarget ?? cool case final double value) {
      payload['coolSetpoint'] = value;
    }
    if (values['autoChangeoverActive'] is bool) {
      payload['autoChangeoverActive'] = values['autoChangeoverActive'];
    }
    if (values['thermostatSetpointStatus'] is String &&
        id.toUpperCase().startsWith('LCC-')) {
      payload['thermostatSetpointStatus'] =
          values['thermostatSetpointStatus'];
    }
    return payload;
  }

  bool supportsFan(String target) =>
      fanModes.any((v) => v.toLowerCase() == target.toLowerCase());

  double adjustedSetpoint({required bool heating, required int direction}) {
    final value = heating ? heat : cool;
    if (value == null) throw const FormatException('No setpoint available.');
    final next = value + increment * direction;
    final minimum = heating ? minHeat : minCool;
    final maximum = heating ? maxHeat : maxCool;
    if (minimum != null && next < minimum) {
      throw const FormatException('Minimum setpoint reached.');
    }
    if (maximum != null && next > maximum) {
      throw const FormatException('Maximum setpoint reached.');
    }
    // Never cross the existing opposite setpoint.
    if (heating && cool != null && next > cool!) {
      throw const FormatException('Heat cannot exceed cool setpoint.');
    }
    if (!heating && heat != null && next < heat!) {
      throw const FormatException('Cool cannot be below heat setpoint.');
    }
    return next;
  }
}

List<ResideoDevice> parseResideoLocations(Object? payload) {
  if (payload is! List) {
    throw const FormatException('Unexpected Honeywell locations response.');
  }
  final result = <String, ResideoDevice>{};
  for (final location in payload) {
    if (location is! Map) continue;
    final locationId = location['locationID']?.toString() ?? '';
    final locationName = location['name']?.toString() ?? 'Location';
    if (locationId.isEmpty) continue;
    final devices = location['devices'];
    if (devices is! List) continue;
    for (final item in devices) {
      final device = ResideoDevice.fromApi(item, locationId, locationName);
      if (device != null) result['$locationId:${device.id}'] = device;
    }
  }
  final devices = result.values.toList();
  devices.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return devices;
}

class ResideoApiError implements Exception {
  const ResideoApiError(this.message, [this.code = 0]);
  final String message;
  final int code;
  @override
  String toString() => message;
}

class ResideoCredentials {
  const ResideoCredentials({
    required this.apiKey,
    required this.accessToken,
    this.apiSecret = '',
    this.refreshToken = '',
    this.redirectUri = '',
  });
  final String apiKey, apiSecret, accessToken, refreshToken, redirectUri;
  bool get usable => apiKey.isNotEmpty &&
      (accessToken.isNotEmpty ||
          (apiSecret.isNotEmpty && refreshToken.isNotEmpty));
}

class ResideoConnection {
  ResideoConnection({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        );

  static const apiHost = 'api.honeywellhome.com';
  static const _prefix = 'taptether.honeywellhome.v1.';
  final FlutterSecureStorage _storage;

  Future<ResideoCredentials> credentials() async {
    final values = await Future.wait([
      _storage.read(key: '${_prefix}apiKey'),
      _storage.read(key: '${_prefix}apiSecret'),
      _storage.read(key: '${_prefix}accessToken'),
      _storage.read(key: '${_prefix}refreshToken'),
      _storage.read(key: '${_prefix}redirectUri'),
    ]);
    return ResideoCredentials(
      apiKey: values[0] ?? '',
      apiSecret: values[1] ?? '',
      accessToken: values[2] ?? '',
      refreshToken: values[3] ?? '',
      redirectUri: values[4] ?? '',
    );
  }

  Future<void> save(ResideoCredentials c) async {
    if (c.apiKey.trim().isEmpty) {
      throw const FormatException('Honeywell API key is required.');
    }
    if (c.apiSecret.isNotEmpty != c.refreshToken.isNotEmpty &&
        c.accessToken.isEmpty) {
      throw const FormatException('Enter an access token or both a secret and refresh token.');
    }
    await _storage.write(key: '${_prefix}apiKey', value: c.apiKey.trim());
    await _storage.write(key: '${_prefix}apiSecret', value: c.apiSecret.trim());
    await _storage.write(
        key: '${_prefix}accessToken', value: c.accessToken.trim());
    await _storage.write(
        key: '${_prefix}refreshToken', value: c.refreshToken.trim());
    await _storage.write(
        key: '${_prefix}redirectUri', value: c.redirectUri.trim());
  }

  Future<void> disconnect() async {
    for (final name in [
      'apiKey', 'apiSecret', 'accessToken', 'refreshToken', 'redirectUri',
    ]) {
      await _storage.delete(key: '$_prefix$name');
    }
  }

  static Uri authorizationUrl(String key, String redirect) {
    final target = Uri.tryParse(redirect.trim());
    if (key.trim().isEmpty || target == null ||
        target.scheme != 'https' || target.host.isEmpty ||
        target.userInfo.isNotEmpty) {
      throw const FormatException('Provide an API key and registered HTTPS redirect URL.');
    }
    return Uri.https(apiHost, '/oauth2/authorize', {
      'response_type': 'code',
      'client_id': key.trim(),
      'redirect_uri': redirect.trim(),
      'appSelect': '1',
    });
  }

  static String authorizationCode(String input) {
    final trimmed = input.trim();
    final url = Uri.tryParse(trimmed);
    if (url != null && url.hasScheme) {
      final code = url.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw const FormatException('Redirect URL does not contain an authorization code.');
      }
      return code;
    }
    if (trimmed.isEmpty) throw const FormatException('Authorization code required.');
    return trimmed;
  }

  Future<Object?> _request(Uri uri, {
    String? bearer,
    String? basic,
    Map<String, String>? form,
    Map<String, Object?>? json,
  }) async {
    if (uri.scheme != 'https' || uri.host != apiHost) {
      throw const FormatException('Only Honeywell Home API HTTPS requests are allowed.');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = form != null || json != null
          ? await client.postUrl(uri) : await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (basic != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Basic $basic');
      }
      if (form != null) {
        request.headers.contentType =
            ContentType('application', 'x-www-form-urlencoded');
        request.write(form.entries.map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&'));
      } else if (json != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(json));
      }
      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await utf8.decoder.bind(response).join()
          .timeout(const Duration(seconds: 30));
      Object? data;
      try {
        data = jsonDecode(text);
      } catch (_) {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return null; // Successful write operations may return an empty body.
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = data is Map
            ? (data['message'] ?? data['error_description'] ?? data['error'])
                ?.toString() : null;
        throw ResideoApiError(
          response.statusCode == 401 ? 'Honeywell token expired or invalid.'
              : response.statusCode == 429 ? 'Honeywell rate limit reached. Retry later.'
              : error ?? 'Honeywell API request failed (${response.statusCode}).',
          response.statusCode);
      }
      return data;
    } on SocketException {
      throw const ResideoApiError('Cannot reach Honeywell Home API.');
    } on HandshakeException {
      throw const ResideoApiError('Could not verify Honeywell HTTPS connection.');
    } finally {
      client.close(force: true);
    }
  }

  Future<ResideoCredentials> _exchange(
      ResideoCredentials c, Map<String, String> fields) async {
    if (c.apiKey.isEmpty || c.apiSecret.isEmpty) {
      throw const FormatException('API key and secret are needed for token exchange.');
    }
    final basic = base64Encode(utf8.encode('${c.apiKey}:${c.apiSecret}'));
    final result = await _request(
      Uri.https(apiHost, '/oauth2/token'), basic: basic, form: fields,
    );
    if (result is! Map || result['access_token'] is! String) {
      throw const ResideoApiError('No access token returned by Honeywell.');
    }
    return ResideoCredentials(
      apiKey: c.apiKey,
      apiSecret: c.apiSecret,
      accessToken: result['access_token'] as String,
      refreshToken: (result['refresh_token'] ?? c.refreshToken).toString(),
      redirectUri: c.redirectUri,
    );
  }

  Future<void> exchangeCode(ResideoCredentials provided, String input) async {
    if (provided.redirectUri.trim().isEmpty) {
      throw const FormatException('Enter the registered OAuth redirect URL.');
    }
    final result = await _exchange(provided, {
      'grant_type': 'authorization_code',
      'code': authorizationCode(input),
      'redirect_uri': provided.redirectUri.trim(),
    });
    await save(result);
  }

  Future<ResideoCredentials> _token(ResideoCredentials c) async {
    if (c.accessToken.isNotEmpty) return c;
    if (c.refreshToken.isEmpty || c.apiSecret.isEmpty) {
      throw const ResideoApiError('Enter a Honeywell OAuth access token in settings.');
    }
    return _refresh(c);
  }

  Future<ResideoCredentials> _refresh(ResideoCredentials c) async {
    final fresh = await _exchange(c, {
      'grant_type': 'refresh_token', 'refresh_token': c.refreshToken,
    });
    await save(fresh);
    return fresh;
  }

  Future<Object?> _call(Uri uri, {Map<String, Object?>? body}) async {
    var current = await _token(await credentials());
    try {
      return await _request(uri, bearer: current.accessToken, json: body);
    } on ResideoApiError catch (error) {
      if (error.code != 401 || current.refreshToken.isEmpty ||
          current.apiSecret.isEmpty) rethrow;
      current = await _refresh(current);
      return _request(uri, bearer: current.accessToken, json: body);
    }
  }

  static Uri locationUrl(String key) => Uri.https(
    apiHost, '/v2/locations', {'apikey': key},
  );

  static Uri thermostatUrl(String key, String locationId, String deviceId,
      {bool fan = false}) => Uri.https(
    apiHost,
    '/v2/devices/thermostats/${Uri.encodeComponent(deviceId)}${fan ? '/fan' : ''}',
    {'apikey': key, 'locationId': locationId},
  );

  Future<List<ResideoDevice>> discover() async {
    final c = await credentials();
    if (!c.usable) {
      throw const ResideoApiError('Configure Honeywell API credentials first.');
    }
    final raw = await _call(locationUrl(c.apiKey));
    final listed = parseResideoLocations(raw);
    if (raw is! List) return listed;
    // Fetch complete, current thermostat settings per location when available.
    // No background polling or LAN scan is involved.
    final merged = <String, ResideoDevice>{
      for (final d in listed) '${d.locationId}:${d.id}': d,
    };
    for (final item in raw) {
      if (item is! Map || item['locationID'] == null) continue;
      final locationId = item['locationID'].toString();
      final locationName = item['name']?.toString() ?? 'Location';
      try {
        final result = await _call(Uri.https(
          apiHost, '/v2/devices/thermostats',
          {'apikey': c.apiKey, 'locationId': locationId},
        ));
        if (result is! List) continue;
        for (final device in result) {
          final parsed = ResideoDevice.fromApi(device, locationId, locationName);
          if (parsed != null) merged['$locationId:${parsed.id}'] = parsed;
        }
      } on ResideoApiError catch (error) {
        if (merged.isEmpty) rethrow;
        if (error.code == 401) rethrow;
      }
    }
    final devices = merged.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return devices;
  }

  Future<void> mode(ResideoDevice device, String selected, {
    bool fan = false,
    double? heat,
    double? cool,
  }) async {
    if (!device.online) {
      throw const ResideoApiError('This thermostat is currently offline.');
    }
    final c = await credentials();
    final body = fan
        ? <String, Object?>{'mode': selected}
        : device.systemPayload(selected, heatTarget: heat, coolTarget: cool);
    if (fan && !device.supportsFan(selected)) {
      throw const FormatException('Fan mode is not supported by the device.');
    }
    await _call(thermostatUrl(c.apiKey, device.locationId, device.id, fan: fan),
        body: body);
  }
}
