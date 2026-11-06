import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:xml/xml.dart';

/// Local-only Luma NVR ISAPI integration. No cloud or backend receives secrets.
class LumaNvrException implements Exception {
  const LumaNvrException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LumaNvrSettings {
  const LumaNvrSettings({
    required this.host,
    required this.username,
    required this.password,
    this.port = 443,
  });

  final String host;
  final int port;
  final String username;
  final String password;

  String get address => port == 443 ? host : '$host:$port';

  static LumaNvrSettings fromInput(
      String address, String username, String password) {
    final value = address.trim();
    if (value.isEmpty || value.contains('/') || value.contains('@') ||
        value.contains('?') || value.contains('#') ||
        value.contains(RegExp(r'\s'))) {
      throw const LumaNvrException('Enter the NVR IP or host, without https://.');
    }
    final parts = value.split(':');
    if (parts.length > 2 || parts.first.isEmpty ||
        !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(parts.first) ||
        parts.first.startsWith('-') || parts.first.endsWith('-') ||
        parts.first.length > 253) {
      throw const LumaNvrException('Enter a valid NVR host or IPv4 address.');
    }
    final port = parts.length == 2 ? int.tryParse(parts[1]) : 443;
    if (port == null || port < 1 || port > 65535) {
      throw const LumaNvrException('Enter a valid port (1–65535).');
    }
    if (username.trim().isEmpty || password.isEmpty) {
      throw const LumaNvrException('NVR username and password are required.');
    }
    return LumaNvrSettings(
      host: parts.first.toLowerCase(),
      port: port,
      username: username.trim(),
      password: password,
    );
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'username': username,
    'password': password,
  };

  factory LumaNvrSettings.fromJson(Map<String, dynamic> data) =>
      fromInput('${data['host']}:${data['port'] ?? 443}',
          (data['username'] ?? '').toString(),
          (data['password'] ?? '').toString());
}

class LumaSecureStore {
  LumaSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'taptether_luma_nvr_v1';
  final FlutterSecureStorage _storage;

  Future<LumaNvrSettings?> load() async {
    final value = await _storage.read(key: key);
    if (value == null || value.isEmpty) return null;
    return LumaNvrSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map));
  }

  Future<void> save(LumaNvrSettings settings) =>
      _storage.write(key: key, value: jsonEncode(settings.toJson()));

  Future<void> remove() => _storage.delete(key: key);
}

class LumaCamera {
  const LumaCamera({
    required this.channel,
    required this.name,
    this.online,
  });
  final int channel;
  final String name;
  final bool? online;
}

class LumaDeviceInfo {
  const LumaDeviceInfo({
    required this.name,
    required this.model,
    required this.firmware,
    required this.serial,
  });
  final String name;
  final String model;
  final String firmware;
  final String serial;
}

String lumaXmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

int lumaChannel(int value) {
  if (value < 1 || value > 64) {
    throw const LumaNvrException('Camera channel must be 1–64.');
  }
  return value;
}

String lumaSnapshotPath(int channel) =>
    '/ISAPI/Streaming/channels/${lumaChannel(channel)}01/picture';

String lumaPreviewPath(int channel) =>
    '/ISAPI/Streaming/channels/${lumaChannel(channel)}01/httpPreview';

String? _lumaTag(XmlElement element, String name) {
  for (final child in element.children.whereType<XmlElement>()) {
    if (child.name.local == name) return child.innerText.trim();
  }
  return null;
}

Iterable<XmlElement> _lumaElements(String xml, String tag) {
  final document = XmlDocument.parse(xml);
  return document.descendants.whereType<XmlElement>()
      .where((element) => element.name.local == tag);
}

LumaDeviceInfo parseLumaDeviceInfo(String response) {
  final element = _lumaElements(response, 'DeviceInfo').firstOrNull;
  if (element == null) {
    throw const LumaNvrException('The NVR did not return device information.');
  }
  return LumaDeviceInfo(
    name: _lumaTag(element, 'deviceName') ?? 'Luma NVR',
    model: _lumaTag(element, 'model') ?? '',
    firmware: _lumaTag(element, 'firmwareVersion') ?? '',
    serial: _lumaTag(element, 'serialNumber') ?? '',
  );
}

List<LumaCamera> parseLumaCameras(String channelsXml, String? statusXml) {
  final states = <int, bool>{};
  if (statusXml != null) {
    for (final element in _lumaElements(
        statusXml, 'InputProxyChannelStatus')) {
      final id = int.tryParse(_lumaTag(element, 'id') ?? '');
      final value = (_lumaTag(element, 'online') ?? '').toLowerCase();
      if (id != null && id >= 1 && id <= 64) {
        if (value == 'true' || value == '1') states[id] = true;
        if (value == 'false' || value == '0') states[id] = false;
      }
    }
  }
  final result = <LumaCamera>[];
  final seen = <int>{};
  for (final element in _lumaElements(channelsXml, 'InputProxyChannel')) {
    final channel = int.tryParse(_lumaTag(element, 'id') ?? '');
    if (channel == null || channel < 1 || channel > 64 ||
        !seen.add(channel)) {
      continue;
    }
    final name = _lumaTag(element, 'name') ??
        'Camera $channel';
    result.add(LumaCamera(
        channel: channel,
        name: name.isEmpty ? 'Camera $channel' : name,
        online: states[channel]));
  }
  result.sort((a, b) => a.channel.compareTo(b.channel));
  return result;
}

Map<String, String> parseLumaFields(
    String xml, List<String> fields) {
  final document = XmlDocument.parse(xml);
  final values = <String, String>{};
  for (final node in document.descendants.whereType<XmlElement>()) {
    if (fields.contains(node.name.local) &&
        !values.containsKey(node.name.local)) {
      values[node.name.local] = node.innerText.trim();
    }
  }
  return values;
}

void validateLumaPut(String xml) {
  final fields = parseLumaFields(xml, ['statusCode', 'statusString']);
  if (fields['statusCode'] != '1') {
    throw LumaNvrException(fields['statusString'] ??
        'The NVR rejected this settings change.');
  }
}

/// Distinguishes a reachable TCP port from an HTTPS/ISAPI endpoint.
/// The Luma mobile-app SDK/server port is a different, proprietary protocol.
String lumaPortDiagnosis({required bool tcpReachable, required int port}) {
  if (tcpReachable) {
    return 'TCP port $port is reachable, but it did not answer as '
        'HTTPS/ISAPI. The Luma mobile app uses a separate SDK Server port '
        '(usually 8000, sometimes forwarded to a different number). '
        'TapTether needs the NVR HTTPS/Web port (usually 443). '
        'For access away from the recorder, use a VPN.';
  }
  return 'Cannot reach TCP port $port at this NVR address. '
      'Check the NVR HTTPS/Web port (usually 443), then use the '
      'same Wi-Fi or a VPN to reach its private address. '
      'The port configured in the Luma mobile app may be the '
      'different SDK Server port.';
}

/// Only the configured NVR is contacted; redirects are rejected so HTTP Basic
/// credentials cannot be forwarded to another host.
class LumaNvrClient {
  LumaNvrClient(this.settings, {HttpClient? http})
      : _http = http ?? _newHttp(settings);

  final LumaNvrSettings settings;
  final HttpClient _http;
  static const requestTimeout = Duration(seconds: 8);
  static const maxImageBytes = 8 * 1024 * 1024;

  static HttpClient _newHttp(LumaNvrSettings settings) {
    final client = HttpClient(
        context: SecurityContext(withTrustedRoots: true));
    client.connectionTimeout = requestTimeout;
    client.autoUncompress = false;
    // This exception is limited to a single explicitly configured HTTPS NVR.
    // It does not disable verification for any other host or app request.
    client.badCertificateCallback = (cert, host, port) =>
        host.toLowerCase() == settings.host && port == settings.port;
    return client;
  }

  /// Read-only network check. No username or password is transmitted.
  /// A successful TCP connection does not mean this is an ISAPI port.
  Future<String> diagnoseFailedConnection() async {
    try {
      final socket = await Socket.connect(settings.host, settings.port,
          timeout: const Duration(seconds: 3));
      socket.destroy();
      return lumaPortDiagnosis(tcpReachable: true, port: settings.port);
    } catch (_) {
      return lumaPortDiagnosis(tcpReachable: false, port: settings.port);
    }
  }

  Uri _url(String path) => Uri(
      scheme: 'https',
      host: settings.host,
      port: settings.port,
      path: path);

  Future<HttpClientResponse> _open(
      String method, String path, {String? xml}) async {
    try {
      final request = await _http.openUrl(method, _url(path))
          .timeout(requestTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Basic '
          '${base64Encode(utf8.encode('${settings.username}:${settings.password}'))}');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (xml != null) {
        request.headers.contentType =
            ContentType('application', 'xml', charset: 'utf-8');
        request.write(xml);
      }
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode != 200 &&
          response.statusCode != 201 &&
          response.statusCode != 204) {
        response.drain<void>().ignore();
        if (response.statusCode == 401 ||
            response.statusCode == 403) {
          throw const LumaNvrException(
              'NVR login rejected. Check username and password.');
        }
        throw LumaNvrException(
            'NVR request failed (HTTP ${response.statusCode}).');
      }
      return response;
    } on LumaNvrException {
      rethrow;
    } on HandshakeException {
      throw const LumaNvrException(
          'NVR TLS handshake failed. Older Luma firmware may require a '
          'legacy cipher not supported by iOS.');
    } on SocketException {
      throw const LumaNvrException(
          'Cannot reach the NVR. Check its LAN address and Wi-Fi.');
    } on TimeoutException {
      throw const LumaNvrException('NVR did not respond within 8 seconds.');
    } on HttpException {
      throw const LumaNvrException('NVR returned an invalid HTTP response.');
    }
  }

  Future<Uint8List> _readBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(requestTimeout)) {
      if (builder.length + chunk.length > maxImageBytes) {
        throw const LumaNvrException('NVR response is too large.');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<String> _readXml(String method, String path, {String? xml}) async {
    final response = await _open(method, path, xml: xml);
    final data = await _readBytes(response);
    return utf8.decode(data, allowMalformed: true);
  }

  Future<LumaDeviceInfo> deviceInfo() async =>
      parseLumaDeviceInfo(
          await _readXml('GET', '/ISAPI/System/deviceInfo'));

  Future<List<LumaCamera>> cameras() async {
    final list = await _readXml(
        'GET', '/ISAPI/ContentMgmt/InputProxy/channels');
    String? statuses;
    try {
      statuses = await _readXml(
          'GET', '/ISAPI/ContentMgmt/InputProxy/channels/status');
    } catch (_) {
      // Unknown state must not be interpreted as offline.
    }
    return parseLumaCameras(list, statuses);
  }

  Future<Uint8List> snapshot(int channel) async {
    final response = await _open('GET', lumaSnapshotPath(channel));
    return _readBytes(response);
  }

  /// Live responses intentionally have NO idle/read timeout.
  /// The viewer owns this client and closes it on dismissal.
  Future<HttpClientResponse> live(int channel) =>
      _open('GET', lumaPreviewPath(channel));

  Future<Map<String, String>> systemTime() async =>
      parseLumaFields(await _readXml('GET', '/ISAPI/System/time'),
          ['timeMode', 'localTime', 'timeZone']);

  Future<Map<String, String>> ntp() async =>
      parseLumaFields(await _readXml(
          'GET', '/ISAPI/System/time/ntpServers/1'),
          ['hostName', 'portNo', 'synchronizeInterval']);

  Future<Map<String, String>> network() async =>
      parseLumaFields(await _readXml(
          'GET', '/ISAPI/System/Network/interfaces'),
          ['ipAddress', 'subnetMask', 'defaultGateway', 'speed']);

  Future<void> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 32) {
      throw const LumaNvrException(
          'Recorder name must contain 1–32 characters.');
    }
    final xml = '<DeviceInfo version="1.0" '
        'xmlns="http://www.isapi.org/ver20/XMLSchema">'
        '<deviceName>${lumaXmlEscape(trimmed)}</deviceName></DeviceInfo>';
    validateLumaPut(await _readXml(
        'PUT', '/ISAPI/System/deviceInfo', xml: xml));
  }

  Future<void> updateNtp({
    required String hostName,
    required int port,
    required int intervalMinutes,
  }) async {
    if (hostName.trim().isEmpty ||
        hostName.contains(RegExp(r'[\s/<>&]')) ||
        port < 1 || port > 65535 ||
        intervalMinutes < 1 || intervalMinutes > 10080) {
      throw const LumaNvrException('Invalid NTP server settings.');
    }
    final xml = '<NTPServer version="1.0" '
        'xmlns="http://www.isapi.org/ver20/XMLSchema">'
        '<id>1</id>'
        '<hostName>${lumaXmlEscape(hostName.trim())}</hostName>'
        '<portNo>$port</portNo>'
        '<synchronizeInterval>$intervalMinutes</synchronizeInterval>'
        '</NTPServer>';
    validateLumaPut(await _readXml(
        'PUT', '/ISAPI/System/time/ntpServers/1', xml: xml));
  }

  Future<void> updateTime({
    required String mode,
    required String localTime,
    required String timeZone,
  }) async {
    if (mode != 'NTP' && mode != 'manual') {
      throw const LumaNvrException('Choose NTP or manual time.');
    }
    if (timeZone.trim().isEmpty || timeZone.length > 80 ||
        (mode == 'manual' && !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')
              .hasMatch(localTime))) {
      throw const LumaNvrException('Enter a valid NVR time and time zone.');
    }
    final xml = '<Time version="1.0" '
        'xmlns="http://www.isapi.org/ver20/XMLSchema">'
        '<timeMode>$mode</timeMode>'
        '<localTime>${lumaXmlEscape(localTime)}</localTime>'
        '<timeZone>${lumaXmlEscape(timeZone.trim())}</timeZone>'
        '</Time>';
    validateLumaPut(await _readXml(
        'PUT', '/ISAPI/System/time', xml: xml));
  }

  void close() => _http.close(force: true);
}
