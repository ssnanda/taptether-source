import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Official Govee Developer Platform v1. No passwords or account cookies.
class GoveeApiException implements Exception {
  const GoveeApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GoveeCapability {
  const GoveeCapability(this.type, this.instance, this.parameters);
  final String type;
  final String instance;
  final Map<String, dynamic> parameters;

  factory GoveeCapability.fromJson(Map<String, dynamic> data) =>
      GoveeCapability(
        data['type']?.toString() ?? '',
        data['instance']?.toString() ?? '',
        Map<String, dynamic>.from(data['parameters'] is Map
            ? data['parameters'] as Map : const {}),
      );

  List<(String, int)> get options {
    final raw = parameters['options'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((item) => (
      item['name']?.toString() ?? '',
      item['value'] is num ? (item['value'] as num).toInt() : -1,
    )).where((item) => item.$1.isNotEmpty && item.$2 >= 0).toList();
  }
}

class GoveeDevice {
  const GoveeDevice({
    required this.sku,
    required this.id,
    required this.name,
    required this.kind,
    required this.capabilities,
    this.online,
    this.powered,
    this.brightness,
    this.color,
    this.colorTemperature,
    this.scene,
  });
  final String sku;
  final String id;
  final String name;
  final String kind;
  final List<GoveeCapability> capabilities;
  final bool? online;
  final bool? powered;
  final int? brightness;
  final int? color;
  final int? colorTemperature;
  final int? scene;

  factory GoveeDevice.fromJson(Map<String, dynamic> json) {
    final caps = json['capabilities'];
    return GoveeDevice(
      sku: json['sku']?.toString() ?? '',
      id: json['device']?.toString() ?? '',
      name: (json['deviceName']?.toString().trim().isNotEmpty ?? false)
          ? json['deviceName'].toString().trim()
          : json['sku']?.toString() ?? 'Govee device',
      kind: json['type']?.toString() ?? '',
      capabilities: caps is List
          ? caps.whereType<Map>()
              .map((e) => GoveeCapability.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }

  GoveeCapability? capability(String type, String instance) {
    for (final cap in capabilities) {
      if (cap.type == type && cap.instance == instance) return cap;
    }
    return null;
  }

  bool get hasPower => capability('devices.capabilities.on_off', 'powerSwitch') != null;
  bool get hasBrightness => capability('devices.capabilities.range', 'brightness') != null;
  bool get hasColor => capability('devices.capabilities.color_setting', 'colorRgb') != null;
  bool get hasTemperature => capability('devices.capabilities.color_setting', 'colorTemperatureK') != null;
  bool get hasScenes => capability('devices.capabilities.dynamic_scene', 'lightScene') != null;
  bool get isLight => kind == 'devices.types.light';

  GoveeDevice withLocal({
    bool? powered, int? brightness, int? color, int? colorTemperature, int? scene,
  }) => GoveeDevice(
    sku: sku, id: id, name: name, kind: kind, capabilities: capabilities,
    online: online, powered: powered ?? this.powered,
    brightness: brightness ?? this.brightness, color: color ?? this.color,
    colorTemperature: colorTemperature ?? this.colorTemperature,
    scene: scene ?? this.scene,
  );

  GoveeDevice withState(Map<String, dynamic> payload) {
    bool? newOnline = online, newPower = powered;
    int? newBrightness = brightness, newColor = color;
    int? newTemperature = colorTemperature, newScene = scene;
    final list = payload['capabilities'];
    if (list is List) {
      for (final c in list.whereType<Map>()) {
        final instance = c['instance']?.toString();
        final state = c['state'];
        final value = state is Map ? state['value'] : null;
        switch (instance) {
          case 'online':
            if (value is bool) newOnline = value;
            break;
          case 'powerSwitch':
            if (value is num) newPower = value != 0;
            break;
          case 'brightness':
            if (value is num) newBrightness = value.toInt();
            break;
          case 'colorRgb':
            if (value is num) newColor = value.toInt();
            break;
          case 'colorTemperatureK':
            if (value is num) newTemperature = value.toInt();
            break;
          case 'lightScene':
            if (value is num) newScene = value.toInt();
            break;
        }
      }
    }
    return GoveeDevice(
      sku: sku, id: id, name: name, kind: kind, capabilities: capabilities,
      online: newOnline, powered: newPower, brightness: newBrightness,
      color: newColor, colorTemperature: newTemperature, scene: newScene,
    );
  }
}

class GoveeConnection {
  GoveeConnection({HttpClient? http, FlutterSecureStorage? storage})
      : _http = http ?? HttpClient(),
        _storage = storage ?? const FlutterSecureStorage();

  static const _keySlot = 'taptether_govee_developer_key_v1';
  static final Uri _origin = Uri.parse('https://openapi.api.govee.com');
  final HttpClient _http;
  final FlutterSecureStorage _storage;
  String? _key;
  static List<GoveeDevice> cachedDevices = const [];

  Future<bool> restore() async {
    _key = (await _storage.read(key: _keySlot))?.trim();
    return _key?.isNotEmpty ?? false;
  }

  Future<void> saveKey(String value) async {
    final key = value.trim();
    if (key.isEmpty || key.contains(RegExp(r'\s'))) {
      throw const GoveeApiException('Enter the API key from Govee Home.');
    }
    // Validate before overwriting a working key.
    await _call('/router/api/v1/user/devices', key: key);
    await _storage.write(key: _keySlot, value: key);
    _key = key;
    cachedDevices = const [];
  }

  Future<void> disconnect() async {
    _key = null;
    cachedDevices = const [];
    await _storage.delete(key: _keySlot);
  }

  Future<Map<String, dynamic>> _call(
    String path, {String? key, Map<String, dynamic>? body}
  ) async {
    final auth = key ?? _key;
    if (auth == null || auth.isEmpty) {
      throw const GoveeApiException('Connect your Govee API key in Settings.');
    }
    try {
      final uri = _origin.resolve(path);
      final request = await (body == null
          ? _http.getUrl(uri) : _http.postUrl(uri))
          .timeout(const Duration(seconds: 12));
      request.headers.set('Govee-API-Key', auth);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(const Duration(seconds: 12));
      final raw = await utf8.decoder.bind(response).join()
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const GoveeApiException('Govee API key was rejected.');
      }
      if (response.statusCode == 429) {
        throw const GoveeApiException('Govee rate limit reached. Try again shortly.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GoveeApiException('Govee request failed (HTTP ${response.statusCode}).');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const GoveeApiException('Govee returned an unexpected response.');
      }
      final result = Map<String, dynamic>.from(decoded);
      if (result['code'] != 200) {
        throw GoveeApiException('Govee request failed (code ${result['code']}).');
      }
      return result;
    } on GoveeApiException {
      rethrow;
    } on SocketException {
      throw const GoveeApiException('Unable to reach Govee. Check internet access.');
    } on HandshakeException {
      throw const GoveeApiException('Could not establish a secure Govee connection.');
    } on FormatException {
      throw const GoveeApiException('Govee returned invalid device data.');
    } on Exception {
      throw const GoveeApiException('Govee request timed out or failed.');
    }
  }

  Future<List<GoveeDevice>> devices() async {
    final result = await _call('/router/api/v1/user/devices');
    final raw = result['data'];
    if (raw is! List) {
      throw const GoveeApiException('Govee returned an invalid device list.');
    }
    final devices = raw.whereType<Map>()
        .map((json) => GoveeDevice.fromJson(Map<String, dynamic>.from(json)))
        .where((d) => d.id.isNotEmpty && d.sku.isNotEmpty).toList();
    cachedDevices = devices;
    return devices;
  }

  Future<GoveeDevice> updateState(GoveeDevice device) async {
    final result = await _call('/router/api/v1/device/state', body: {
      'requestId': DateTime.now().microsecondsSinceEpoch.toString(),
      'payload': {'sku': device.sku, 'device': device.id},
    });
    final payload = result['payload'];
    return payload is Map
        ? device.withState(Map<String, dynamic>.from(payload))
        : device;
  }

  Future<void> setCapability(
    GoveeDevice device, String type, String instance, Object value,
  ) async {
    if (device.capability(type, instance) == null) {
      throw const GoveeApiException('This device does not support that control.');
    }
    await _call('/router/api/v1/device/control', body: {
      'requestId': DateTime.now().microsecondsSinceEpoch.toString(),
      'payload': {
        'sku': device.sku,
        'device': device.id,
        'capability': {'type': type, 'instance': instance, 'value': value},
      },
    });
  }

  Future<void> power(GoveeDevice device, bool on) =>
      setCapability(device, 'devices.capabilities.on_off', 'powerSwitch', on ? 1 : 0);
  Future<void> brightness(GoveeDevice device, int value) =>
      setCapability(device, 'devices.capabilities.range', 'brightness', value.clamp(1, 100));
  Future<void> rgb(GoveeDevice device, int value) =>
      setCapability(device, 'devices.capabilities.color_setting', 'colorRgb', value & 0xffffff);
  Future<void> temperature(GoveeDevice device, int kelvin) =>
      setCapability(device, 'devices.capabilities.color_setting', 'colorTemperatureK', kelvin);
  Future<void> scene(GoveeDevice device, int scene) =>
      setCapability(device, 'devices.capabilities.dynamic_scene', 'lightScene', scene);

  void close() => _http.close(force: true);
}
