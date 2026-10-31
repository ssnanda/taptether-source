import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'resideo_local_vault.dart';

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
    if (id.isEmpty || id.length > 180) {
      return null;
    }
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
    final requestedHeat = heatTarget ?? heat;
    final requestedCool = coolTarget ?? cool;
    if (requestedHeat != null) {
      payload['heatSetpoint'] = requestedHeat;
    }
    if (requestedCool != null) {
      payload['coolSetpoint'] = requestedCool;
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
    if (value == null) {
      throw const FormatException('No setpoint available.');
    }
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
    if (location is! Map) {
      continue;
    }
    final locationId = location['locationID']?.toString() ?? '';
    final locationName = location['name']?.toString() ?? 'Location';
    if (locationId.isEmpty) {
      continue;
    }
    final devices = location['devices'];
    if (devices is! List) {
      continue;
    }
    for (final item in devices) {
      final device = ResideoDevice.fromApi(item, locationId, locationName);
      if (device != null) {
        result['$locationId:${device.id}'] = device;
      }
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
    this.expiresAtUtc,
  });
  final String apiKey, apiSecret, accessToken, refreshToken, redirectUri;
  final DateTime? expiresAtUtc;
  bool get usable => apiKey.isNotEmpty &&
      (accessToken.isNotEmpty ||
          (apiSecret.isNotEmpty && refreshToken.isNotEmpty));
}

class ResideoConnection {
  ResideoConnection({FlutterSecureStorage? storage})
      : _vault = ResideoLocalVault(storage: storage);

  static const apiHost = 'api.honeywellhome.com';
  static const defaultRedirect = 'http://localhost:7681/';
  final ResideoLocalVault _vault;

  Future<ResideoCredentials> credentials() async {
    final values = await _vault.read() ?? {};
    final expiry = values['expiresAtUtc']?.toString();
    return ResideoCredentials(
      apiKey: values['apiKey']?.toString() ?? '',
      apiSecret: values['apiSecret']?.toString() ?? '',
      accessToken: values['accessToken']?.toString() ?? '',
      refreshToken: values['refreshToken']?.toString() ?? '',
      redirectUri: values['redirectUri']?.toString() ?? defaultRedirect,
      expiresAtUtc: expiry == null ? null : DateTime.tryParse(expiry)?.toUtc(),
    );
  }

  /// Connection details can be saved before receiving an OAuth token.
  Future<void> save(ResideoCredentials c) async {
    if (c.apiKey.trim().isEmpty || c.apiSecret.trim().isEmpty) {
      throw const FormatException('Consumer Key and Consumer Secret are required.');
    }
    validateRedirect(c.redirectUri);
    await _vault.write({
      'apiKey': c.apiKey.trim(),
      'apiSecret': c.apiSecret.trim(),
      'accessToken': c.accessToken.trim(),
      'refreshToken': c.refreshToken.trim(),
      'redirectUri': c.redirectUri.trim(),
      if (c.expiresAtUtc != null)
        'expiresAtUtc': c.expiresAtUtc!.toUtc().toIso8601String(),
    });
  }

  Future<void> disconnect() => _vault.clear();

  /// Localhost is a secure OAuth loopback redirect when registered verbatim.
  /// Arbitrary plaintext HTTP endpoints, credentials in URLs and fragments
  /// are intentionally rejected.
  static Uri validateRedirect(String redirect) {
    final uri = Uri.tryParse(redirect.trim());
    final loopback = uri?.scheme == 'http' &&
        (uri?.host == 'localhost' || uri?.host == '127.0.0.1' ||
         uri?.host == '::1');
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment || (!loopback && uri.scheme != 'https')) {
      throw const FormatException(
        'Use the exact registered Callback URL (HTTPS or localhost loopback).');
    }
    return uri;
  }

  static Uri authorizationUrl(String key, String redirect, {String? state}) {
    validateRedirect(redirect);
    if (key.trim().isEmpty) {
      throw const FormatException('Consumer Key is required.');
    }
    return Uri.https(apiHost, '/oauth2/authorize', {
      'response_type': 'code',
      'client_id': key.trim(),
      'scope': 'devices',
      'redirect_uri': redirect.trim(),
      if (state != null) 'state': state,
    });
  }

  static String authorizationCode(String input,
      {String? redirect, String? state}) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) {
      if (redirect != null) {
        final expected = validateRedirect(redirect);
        if (uri.scheme != expected.scheme ||
            uri.host != expected.host ||
            uri.port != expected.port ||
            uri.path != expected.path) {
          throw const FormatException('OAuth redirect URL does not match the Callback URL.');
        }
      }
      if (state != null && uri.queryParameters['state'] != state) {
        throw const FormatException('OAuth state mismatch. Restart sign-in.');
      }
      final error = uri.queryParameters['error'];
      if (error != null) {
        throw const FormatException('Resideo authorization was not approved.');
      }
      final code = uri.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw const FormatException('No authorization code found in callback.');
      }
      return code;
    }
    if (trimmed.isEmpty) {
      throw const FormatException('Authorization code required.');
    }
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
    final seconds = int.tryParse(result['expires_in']?.toString() ?? '');
    return ResideoCredentials(
      apiKey: c.apiKey,
      apiSecret: c.apiSecret,
      accessToken: result['access_token'] as String,
      refreshToken: (result['refresh_token'] ?? c.refreshToken).toString(),
      redirectUri: c.redirectUri,
      expiresAtUtc: seconds == null ? null
          : DateTime.now().toUtc().add(Duration(seconds: seconds)),
    );
  }

  Future<void> exchangeCode(ResideoCredentials provided, String input,
      {String? state}) async {
    final redirect = validateRedirect(provided.redirectUri);
    final result = await _exchange(provided, {
      'grant_type': 'authorization_code',
      'code': authorizationCode(input,
          redirect: redirect.toString(), state: state),
      'redirect_uri': redirect.toString(),
    });
    await save(result);
  }

  Future<ResideoCredentials> _token(ResideoCredentials c) async {
    final expiry = c.expiresAtUtc;
    final stillValid = c.accessToken.isNotEmpty &&
        (expiry == null || expiry.isAfter(
            DateTime.now().toUtc().add(const Duration(minutes: 2))));
    if (stillValid) return c;
    if (c.refreshToken.isEmpty || c.apiSecret.isEmpty) {
      if (c.accessToken.isNotEmpty && expiry == null) return c;
      throw const ResideoApiError(
          'Resideo authorization expired. Sign in to Resideo again.');
    }
    return _refresh(c);
  }

  /// Refresh opportunistically whenever the user opens or resumes controls.
  /// iOS can suspend inactive apps, so this does not promise background renewal.
  Future<void> renewIfNeeded() async {
    final c = await credentials();
    if (c.usable) await _token(c);
  }

  Future<ResideoCredentials> _refresh(ResideoCredentials c) async {
    try {
      final fresh = await _exchange(c, {
        'grant_type': 'refresh_token', 'refresh_token': c.refreshToken,
      });
      await save(fresh);
      return fresh;
    } on ResideoApiError catch (error) {
      if (error.code == 400 || error.code == 401) {
        throw const ResideoApiError(
            'Resideo refresh token expired. Sign in again to reconnect.');
      }
      rethrow;
    }
  }

  Future<Object?> _call(Uri uri, {Map<String, Object?>? body}) async {
    var current = await _token(await credentials());
    try {
      return await _request(uri, bearer: current.accessToken, json: body);
    } on ResideoApiError catch (error) {
      if (error.code != 401 || current.refreshToken.isEmpty ||
          current.apiSecret.isEmpty) {
        rethrow;
      }
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
    if (raw is! List) {
      return listed;
    }
    // Fetch complete, current thermostat settings per location when available.
    // No background polling or LAN scan is involved.
    final merged = <String, ResideoDevice>{
      for (final d in listed) '${d.locationId}:${d.id}': d,
    };
    for (final item in raw) {
      if (item is! Map || item['locationID'] == null) {
        continue;
      }
      final locationId = item['locationID'].toString();
      final locationName = item['name']?.toString() ?? 'Location';
      try {
        final result = await _call(Uri.https(
          apiHost, '/v2/devices/thermostats',
          {'apikey': c.apiKey, 'locationId': locationId},
        ));
        if (result is! List) {
          continue;
        }
        for (final device in result) {
          final parsed = ResideoDevice.fromApi(device, locationId, locationName);
          if (parsed != null) {
            merged['$locationId:${parsed.id}'] = parsed;
          }
        }
      } on ResideoApiError catch (error) {
        if (merged.isEmpty) {
          rethrow;
        }
        if (error.code == 401) {
          rethrow;
        }
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
