import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A private SideLoader API client. Apple credentials, provisioning material,
/// pairing records, and any VPN credentials remain on the SideLoader server.
class SideLoaderApi {
  SideLoaderApi({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();
  static const _serverKey = 'taptether.sideloader.server.v1';
  static const _userKey = 'taptether.sideloader.username.v1';
  static const _passwordKey = 'taptether.sideloader.password.v1';
  final FlutterSecureStorage _storage;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
  Uri? _server;
  String _cookie = '';

  static Uri validateServer(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('Enter a valid SideLoader server address.');
    }
    return uri.replace(path: '/');
  }

  Future<SideLoaderCredentials?> savedCredentials() async {
    final url = await _storage.read(key: _serverKey);
    final username = await _storage.read(key: _userKey);
    final password = await _storage.read(key: _passwordKey);
    if (url == null || username == null || password == null ||
        url.isEmpty || username.isEmpty || password.isEmpty) return null;
    return SideLoaderCredentials(url, username, password);
  }

  Future<void> login(String server, String user, String password,
      {bool remember = true}) async {
    _server = validateServer(server);
    _cookie = '';
    try {
      await _request('POST', '/api/auth/login',
          body: {'username': user, 'password': password});
      final auth = await _request('GET', '/api/auth');
      if (auth['logged_in'] != true) {
        throw const SideLoaderException('SideLoader did not accept the login.');
      }
      if (remember) {
        await _storage.write(key: _serverKey, value: _server.toString());
        await _storage.write(key: _userKey, value: user);
        await _storage.write(key: _passwordKey, value: password);
      } else {
        await clearCredentials();
      }
    } catch (_) {
      _cookie = '';
      rethrow;
    }
  }

  Future<void> clearCredentials() async {
    await _storage.delete(key: _serverKey);
    await _storage.delete(key: _userKey);
    await _storage.delete(key: _passwordKey);
  }

  Future<void> disconnect() async {
    _server = null;
    _cookie = '';
    await clearCredentials();
  }

  Future<SideLoaderState> state() async =>
      SideLoaderState.fromJson(await _request('GET', '/api/state'));

  Future<List<SideLoaderPhoneApp>> inventory(String udid) async {
    final path = Uri(path: '/api/device/apps',
        queryParameters: {'device': udid}).toString();
    final data = await _request('GET', path,
        timeout: const Duration(seconds: 120));
    return (data['apps'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => SideLoaderPhoneApp.fromJson(_asMap(item)))
        .toList();
  }

  Future<List<SideLoaderSourceApp>> sources() async {
    final data = await _request('GET', '/api/sources',
        timeout: const Duration(seconds: 90));
    final result = <SideLoaderSourceApp>[];
    for (final entry in data['sources'] as List? ?? const []) {
      if (entry is! Map) continue;
      final source = _asMap(entry);
      for (final raw in source['apps'] as List? ?? const []) {
        if (raw is! Map) continue;
        final item = _asMap(raw);
        final bundle = _text(item['bundleIdentifier']);
        if (bundle.isEmpty) continue;
        result.add(SideLoaderSourceApp(
          _text(source['id']), _text(source['name']), bundle,
          _text(item['version']), _text(item['buildVersion'])));
      }
    }
    return result;
  }

  Future<String> reinstallLatest(
      SideLoaderSourceApp source, String device) async {
    // Download only: user separately confirms the signing attempt. The server
    // checks the phone inventory and rejects a different IPA bundle identifier.
    final result = await _request('POST', '/api/sources/install', body: {
      'source': source.sourceId,
      'bundleIdentifier': source.bundleId,
      'device': device,
      'reinstall_latest': true,
      'install_now': false,
    }, timeout: const Duration(minutes: 5));
    final app = _text(result['app_id']);
    if (app.isEmpty) {
      throw const SideLoaderException('SideLoader did not import the IPA.');
    }
    return app;
  }

  Future<String> reSign(String device, String app) async {
    final result = await _request('POST', '/api/refresh', body: {
      'device': device, 'app': app, 'force': true,
    });
    final id = _text(result['job']);
    if (id.isEmpty) throw const SideLoaderException('No signing job was created.');
    return id;
  }

  Future<SideLoaderJob?> currentJob() async {
    final result = await _request('GET', '/api/job');
    final value = result['job'];
    return value is Map ? SideLoaderJob.fromJson(_asMap(value)) : null;
  }

  Future<void> sendCode(String code) async {
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      throw const FormatException('Enter exactly six digits.');
    }
    await _request('POST', '/api/job/input', body: {'text': code});
  }

  Future<void> cancelJob() async {
    await _request('POST', '/api/job/cancel', body: {});
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, Object?>? body,
       Duration timeout = const Duration(seconds: 25)}) async {
    final server = _server;
    if (server == null) {
      throw const SideLoaderException('Connect to SideLoader first.');
    }
    try {
      final request = await _client.openUrl(method, server.resolve(path))
          .timeout(timeout);
      request.headers.set('X-Requested-With', 'sideloop');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (_cookie.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, _cookie);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(timeout);
      if (response.cookies.isNotEmpty) {
        _cookie = response.cookies.map(
            (value) => value.name + '=' + value.value).join('; ');
      }
      final text = await utf8.decoder.bind(response).join().timeout(timeout);
      Map<String, dynamic> data;
      try {
        final value = jsonDecode(text);
        data = value is Map ? _asMap(value) : <String, dynamic>{};
      } on FormatException {
        throw const SideLoaderException('Invalid response from SideLoader.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = _text(data['error']);
        throw SideLoaderException(message.isNotEmpty
            ? message : 'SideLoader HTTP ' + response.statusCode.toString());
      }
      return data;
    } on SideLoaderException {
      rethrow;
    } on TimeoutException {
      throw const SideLoaderException('SideLoader did not respond in time.');
    } on SocketException {
      throw const SideLoaderException(
          'SideLoader unreachable. Check Wi-Fi or the private VPN.');
    } on HandshakeException {
      throw const SideLoaderException('Server TLS certificate could not be verified.');
    }
  }

  void close() => _client.close(force: true);
}

class SideLoaderCredentials {
  const SideLoaderCredentials(this.url, this.user, this.password);
  final String url;
  final String user;
  final String password;
}

class SideLoaderException implements Exception {
  const SideLoaderException(this.message);
  final String message;
  @override
  String toString() => message;
}

Map<String, dynamic> _asMap(Map source) =>
    source.map((key, value) => MapEntry(key.toString(), value));
String _text(Object? value) => value?.toString() ?? '';
int? _number(Object? value) => value is num ? value.toInt() :
    int.tryParse(_text(value));
Map<String, dynamic> _child(Object? value) =>
    value is Map ? _asMap(value) : <String, dynamic>{};

class SideLoaderState {
  SideLoaderState(this.now, this.devices, this.apps, this.blocked, this.blockedReason);
  final int now;
  final List<SideLoaderDevice> devices;
  final List<SideLoaderApp> apps;
  final bool blocked;
  final String blockedReason;
  factory SideLoaderState.fromJson(Map<String, dynamic> json) {
    final guard = _child(json['signing_guard']);
    return SideLoaderState(
      _number(json['now']) ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      (json['registered'] as List? ?? const []).whereType<Map>()
          .map((item) => SideLoaderDevice.fromJson(_asMap(item))).toList(),
      (json['apps'] as List? ?? const []).whereType<Map>()
          .map((item) => SideLoaderApp.fromJson(_asMap(item))).toList(),
      guard['blocked'] == true, _text(guard['message']),
    );
  }
}

class SideLoaderDevice {
  SideLoaderDevice(this.udid, this.name, this.reachable);
  final String udid;
  final String name;
  final bool reachable;
  factory SideLoaderDevice.fromJson(Map<String, dynamic> json) {
    final live = _child(json['live']);
    final udid = _text(json['udid']);
    return SideLoaderDevice(udid, _text(json['name']).isEmpty
        ? udid : _text(json['name']), live['reachable'] == true);
  }
}

class SideLoaderApp {
  SideLoaderApp(this.id, this.bundleId, this.name, this.version, this.targets);
  final String id;
  final String bundleId;
  final String name;
  final String version;
  final List<SideLoaderTarget> targets;
  factory SideLoaderApp.fromJson(Map<String, dynamic> json) => SideLoaderApp(
    _text(json['id']), _text(json['bundle_id']),
    _text(json['name']), _text(json['version']),
    (json['targets'] as List? ?? const []).whereType<Map>()
        .map((item) => SideLoaderTarget.fromJson(_asMap(item))).toList(),
  );
  SideLoaderTarget? targetFor(String udid) {
    for (final target in targets) {
      if (target.udid.toLowerCase() == udid.toLowerCase()) return target;
    }
    return null;
  }
}

class SideLoaderTarget {
  SideLoaderTarget(this.udid, this.expiry, this.installation);
  final String udid;
  final int? expiry;
  final String installation;
  factory SideLoaderTarget.fromJson(Map<String, dynamic> json) {
    return SideLoaderTarget(_text(json['udid']),
      _number(_child(json['signature'])['expiry']),
      _text(_child(json['installation'])['state']));
  }
  String remaining(int now) {
    final seconds = expiry == null ? null : expiry! - now;
    if (seconds == null) return 'Signing expiry unavailable';
    if (seconds <= 0) return 'Signing expired';
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (days > 0) return '$days d $hours h left';
    if (hours > 0) return '$hours h $minutes m left';
    return '$minutes m left';
  }
}

class SideLoaderPhoneApp {
  SideLoaderPhoneApp(this.bundleId, this.version);
  final String bundleId;
  final String version;
  factory SideLoaderPhoneApp.fromJson(Map<String, dynamic> json) =>
      SideLoaderPhoneApp(_text(json['bundle_id']), _text(json['version']));
  bool matches(String source) {
    if (bundleId == source) return true;
    if (!bundleId.startsWith('$source.')) return false;
    final tail = bundleId.substring(source.length + 1);
    return RegExp(r'^[A-Z0-9]{10}$').hasMatch(tail);
  }
}

class SideLoaderSourceApp {
  const SideLoaderSourceApp(this.sourceId, this.sourceName,
      this.bundleId, this.version, this.build);
  final String sourceId;
  final String sourceName;
  final String bundleId;
  final String version;
  final String build;
}

class SideLoaderJob {
  SideLoaderJob(this.id, this.title, this.running, this.rc, this.stage,
      this.fraction, this.needsInput, this.acceptsInput,
      this.delivery, this.secondsLeft, this.last);
  final String id;
  final String title;
  final bool running;
  final int? rc;
  final String stage;
  final double? fraction;
  final bool needsInput;
  final bool acceptsInput;
  final String delivery;
  final int? secondsLeft;
  final String last;
  factory SideLoaderJob.fromJson(Map<String, dynamic> json) => SideLoaderJob(
    _text(json['id']), _text(json['title']), json['running'] == true,
    _number(json['rc']), _text(json['stage']),
    json['fraction'] is num ? (json['fraction'] as num).toDouble() : null,
    json['needs_input'] == true, json['accepts_input'] == true,
    _text(json['verification_delivery']),
    _number(json['verification_seconds_remaining']), _text(json['last']),
  );
}
