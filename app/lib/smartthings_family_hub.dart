import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'lan_scan.dart';
import 'network_probes.dart';

/// Family Hub TCP 17654 is a device hint, not an authenticated control API.
class FamilyHubSettings {
  const FamilyHubSettings({
    this.localIp = '', this.deviceId = '', this.personalToken = '',
    this.clientId = '', this.clientSecret = '', this.redirectUri = '',
    this.accessToken = '', this.refreshToken = '', this.expiresUtc = '',
  });
  final String localIp, deviceId, personalToken;
  final String clientId, clientSecret, redirectUri;
  final String accessToken, refreshToken, expiresUtc;
  bool get connected => personalToken.isNotEmpty || accessToken.isNotEmpty;
  bool get oauthReady => clientId.isNotEmpty && clientSecret.isNotEmpty &&
      redirectUri.isNotEmpty;

  FamilyHubSettings copyWith({
    String? localIp, String? deviceId, String? personalToken,
    String? clientId, String? clientSecret, String? redirectUri,
    String? accessToken, String? refreshToken, String? expiresUtc,
  }) => FamilyHubSettings(
    localIp: localIp ?? this.localIp,
    deviceId: deviceId ?? this.deviceId,
    personalToken: personalToken ?? this.personalToken,
    clientId: clientId ?? this.clientId,
    clientSecret: clientSecret ?? this.clientSecret,
    redirectUri: redirectUri ?? this.redirectUri,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresUtc: expiresUtc ?? this.expiresUtc,
  );

  Map<String, String> toJson() => {
    'localIp': localIp, 'deviceId': deviceId,
    'personalToken': personalToken, 'clientId': clientId,
    'clientSecret': clientSecret, 'redirectUri': redirectUri,
    'accessToken': accessToken, 'refreshToken': refreshToken,
    'expiresUtc': expiresUtc,
  };

  factory FamilyHubSettings.fromJson(Map<String, dynamic> json) =>
      FamilyHubSettings(
        localIp: (json['localIp'] ?? '').toString(),
        deviceId: (json['deviceId'] ?? '').toString(),
        personalToken: (json['personalToken'] ?? '').toString(),
        clientId: (json['clientId'] ?? '').toString(),
        clientSecret: (json['clientSecret'] ?? '').toString(),
        redirectUri: (json['redirectUri'] ?? '').toString(),
        accessToken: (json['accessToken'] ?? '').toString(),
        refreshToken: (json['refreshToken'] ?? '').toString(),
        expiresUtc: (json['expiresUtc'] ?? '').toString(),
      );
}

class FamilyHubStore {
  FamilyHubStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();
  static const key = 'taptether.samsung.familyhub.smartthings.v1';
  final FlutterSecureStorage _storage;

  Future<FamilyHubSettings> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) {
      return const FamilyHubSettings();
    }
    try {
      return FamilyHubSettings.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      throw const FormatException('Saved Family Hub configuration unreadable.');
    }
  }

  Future<void> save(FamilyHubSettings config) async {
    if (config.localIp.isNotEmpty && !isPrivateIPv4(config.localIp)) {
      throw const FormatException('Enter a private local Wi-Fi IP.');
    }
    await _storage.write(key: key, value: jsonEncode(config.toJson()));
  }
}

Future<bool> familyHubPortReachable(String ip) async {
  if (!isPrivateIPv4(ip)) {
    return false;
  }
  return await probeTcpPort(ip, 17654,
      timeout: const Duration(milliseconds: 800)) == TcpProbeStatus.open;
}

class FamilyHubDevice {
  const FamilyHubDevice(this.id, this.name, this.model);
  final String id, name, model;

  static bool looksLikeRefrigerator(Map<String, dynamic> data) {
    final hint = [data['name'], data['label'], data['deviceTypeName'],
      data['modelName']].join(' ').toLowerCase();
    if (hint.contains('family hub') || hint.contains('refrigerator') ||
        hint.contains('fridge')) return true;
    final components = data['components'];
    return components is List && components.whereType<Map>().any(
        (row) => ['cooler', 'freezer', 'fridge'].contains(row['id']));
  }

  factory FamilyHubDevice.fromJson(Map<String, dynamic> data) =>
      FamilyHubDevice(
        (data['deviceId'] ?? '').toString(),
        (data['label'] ?? data['name'] ?? 'Samsung refrigerator').toString(),
        (data['modelName'] ?? '').toString(),
      );
}

class FamilyHubStatus {
  const FamilyHubStatus(this.components);
  final Map<String, dynamic> components;

  factory FamilyHubStatus.fromJson(Map<String, dynamic> data) {
    final raw = data['components'];
    if (raw is! Map) {
      throw const FormatException('No refrigerator status returned.');
    }
    return FamilyHubStatus(Map<String, dynamic>.from(raw));
  }

  /// Show only capabilities that the specific refrigerator actually returns.
  List<({String label, String value})> readings() {
    final output = <({String label, String value})>[];
    for (final part in components.entries) {
      if (part.value is! Map) {
        continue;
      }
      final data = part.value as Map;
      for (final spec in [
        ('temperatureMeasurement', 'temperature', 'Temperature'),
        ('thermostatCoolingSetpoint', 'coolingSetpoint', 'Setpoint'),
        ('contactSensor', 'contact', 'Door'),
        ('relativeHumidityMeasurement', 'humidity', 'Humidity'),
      ]) {
        final capability = data[spec.$1];
        final attr = capability is Map ? capability[spec.$2] : null;
        if (attr is! Map || attr['value'] == null) {
          continue;
        }
        final unit = (attr['unit'] ?? '').toString();
        final title = part.key == 'main' ? spec.$3
            : part.key.toString() + ' · ' + spec.$3;
        output.add((label: title,
          value: attr['value'].toString() +
              (unit.isEmpty ? '' : ' ' + unit)));
      }
    }
    return output;
  }
}

class FamilyHubApiException implements Exception {
  const FamilyHubApiException(this.message);
  final String message;
  @override String toString() => message;
}

typedef FamilyHubTransport = Future<Map<String, dynamic>> Function(
    String method, Uri uri, Map<String, String> headers, Object? body);

class FamilyHubClient {
  FamilyHubClient({FamilyHubStore? store, FamilyHubTransport? transport})
      : _store = store ?? FamilyHubStore(), _transport = transport;
  final FamilyHubStore _store;
  final FamilyHubTransport? _transport;
  Future<FamilyHubSettings>? _refreshing;
  static final _id = RegExp(r'^[a-zA-Z0-9-]{1,96}$');

  static Uri checkRedirect(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
      throw const FormatException('Use the registered HTTPS redirect URL.');
    }
    return uri;
  }

  static String newState() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static Uri authorizeUrl(FamilyHubSettings config, String state) {
    if (!config.oauthReady || state.length < 20) {
      throw const FormatException('Enter SmartThings OAuth app settings.');
    }
    checkRedirect(config.redirectUri);
    return Uri.https('api.smartthings.com', '/v1/oauth/authorize', {
      'client_id': config.clientId, 'response_type': 'code',
      'redirect_uri': config.redirectUri, 'state': state,
      'scope': 'r:devices:*',
    });
  }

  static String codeFromCallback(String text, String registered, String state) {
    final uri = Uri.tryParse(text);
    final correct = checkRedirect(registered);
    if (uri == null || uri.scheme != correct.scheme ||
        uri.host != correct.host || uri.path != correct.path ||
        uri.port != correct.port || uri.queryParameters['state'] != state ||
        uri.queryParameters.containsKey('error') ||
        (uri.queryParameters['code'] ?? '').isEmpty) {
      throw const FormatException('Invalid SmartThings OAuth callback.');
    }
    return uri.queryParameters['code']!;
  }

  Future<Map<String, dynamic>> _send(String method, Uri uri,
      Map<String, String> headers, Object? body) async {
    if (uri.scheme != 'https' || uri.host != 'api.smartthings.com') {
      throw const FamilyHubApiException('Untrusted SmartThings host.');
    }
    if (_transport != null) {
      return _transport(method, uri, headers, body);
    }
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await http.openUrl(method, uri)
          .timeout(const Duration(seconds: 12));
      req.followRedirects = false;
      for (final item in headers.entries) {
        req.headers.set(item.key, item.value);
      }
      if (body != null) {
        if (headers['Content-Type'] == 'application/x-www-form-urlencoded') {
          req.write(Uri(queryParameters:
              Map<String, String>.from(body as Map)).query);
        } else {
          req.write(jsonEncode(body));
        }
      }
      final resp = await req.close().timeout(const Duration(seconds: 16));
      final content = await resp.transform(utf8.decoder)
          .join().timeout(const Duration(seconds: 16));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        if (resp.statusCode == 401) {
          throw const FamilyHubApiException('SmartThings token expired.');
        }
        if (resp.statusCode == 403) {
          throw const FamilyHubApiException(
              'SmartThings does not permit access to this device.');
        }
        if (resp.statusCode == 429) {
          throw const FamilyHubApiException('SmartThings rate limited.');
        }
        throw FamilyHubApiException(
            'SmartThings HTTP ' + resp.statusCode.toString());
      }
      if (content.isEmpty) {
        return {};
      }
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        throw const FamilyHubApiException('Unexpected SmartThings response.');
      }
      return Map<String, dynamic>.from(decoded);
    } on SocketException {
      throw const FamilyHubApiException('SmartThings network unavailable.');
    } on TimeoutException {
      throw const FamilyHubApiException('SmartThings request timed out.');
    } on HandshakeException {
      throw const FamilyHubApiException('SmartThings TLS verification failed.');
    } finally {
      http.close(force: true);
    }
  }

  Future<FamilyHubSettings> _exchange(FamilyHubSettings config,
      Map<String, String> params) async {
    final basic = base64Encode(
        utf8.encode(config.clientId + ':' + config.clientSecret));
    final response = await _send('POST',
        Uri.https('api.smartthings.com', '/v1/oauth/token'), {
      'Authorization': 'Basic ' + basic,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    }, params);
    final access = (response['access_token'] ?? '').toString();
    if (access.isEmpty) {
      throw const FamilyHubApiException('SmartThings OAuth token missing.');
    }
    final seconds = response['expires_in'] is num
        ? (response['expires_in'] as num).toInt() : 86400;
    final saved = config.copyWith(
      accessToken: access,
      refreshToken: (response['refresh_token'] ??
          config.refreshToken).toString(),
      personalToken: '',
      expiresUtc: DateTime.now().toUtc()
          .add(Duration(seconds: seconds.clamp(60, 86400)))
          .toIso8601String(),
    );
    await _store.save(saved); // Preserve rotating access and refresh as a pair.
    return saved;
  }

  Future<void> exchangeCode(FamilyHubSettings config, String code) async {
    await _exchange(config, {
      'grant_type': 'authorization_code', 'code': code,
      'client_id': config.clientId, 'redirect_uri': config.redirectUri,
    });
  }

  Future<FamilyHubSettings> _refresh(FamilyHubSettings config) async {
    if (_refreshing != null) {
      return _refreshing!;
    }
    final value = _exchange(config, {
      'grant_type': 'refresh_token',
      'refresh_token': config.refreshToken,
      'client_id': config.clientId,
    });
    _refreshing = value;
    try {
      return await value;
    } finally {
      _refreshing = null;
    }
  }

  Future<String> _token() async {
    final config = await _store.read();
    if (config.personalToken.isNotEmpty) {
      return config.personalToken;
    }
    if (config.accessToken.isEmpty) {
      throw const FamilyHubApiException(
          'Connect a SmartThings account to read refrigerator status.');
    }
    final expires = DateTime.tryParse(config.expiresUtc);
    if (config.refreshToken.isNotEmpty && expires != null &&
        DateTime.now().toUtc().isAfter(
            expires.toUtc().subtract(const Duration(minutes: 5)))) {
      return (await _refresh(config)).accessToken;
    }
    return config.accessToken;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    String token = await _token();
    Future<Map<String, dynamic>> call(String key) => _send('GET',
        Uri.https('api.smartthings.com', path), {
      'Authorization': 'Bearer ' + key, 'Accept': 'application/json',
    }, null);
    try {
      return await call(token);
    } on FamilyHubApiException catch (e) {
      if (e.message != 'SmartThings token expired.') rethrow;
      final config = await _store.read();
      if (config.refreshToken.isEmpty || config.personalToken.isNotEmpty) {
        rethrow;
      }
      token = (await _refresh(config)).accessToken;
      return call(token);
    }
  }

  Future<List<FamilyHubDevice>> refrigerators() async {
    final payload = await _get('/v1/devices');
    final items = payload['items'];
    if (items is! List) {
      return [];
    }
    return items.whereType<Map>().map((x) =>
        Map<String, dynamic>.from(x))
        .where(FamilyHubDevice.looksLikeRefrigerator)
        .map(FamilyHubDevice.fromJson)
        .where((x) => _id.hasMatch(x.id))
        .toList();
  }

  Future<FamilyHubStatus> status(String id) async {
    if (!_id.hasMatch(id)) {
      throw const FormatException('Invalid device ID.');
    }
    return FamilyHubStatus.fromJson(
        await _get('/v1/devices/' + id + '/status'));
  }
}
