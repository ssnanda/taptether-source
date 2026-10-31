import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'automatic_device_backup.dart';

import 'lan_scan.dart';
import 'discovery.dart';
import 'tv_lan_utils.dart';
import 'tv_remote_controller.dart';

/// Local Samsung Tizen / Smart View remote; no agent or cloud account.
class SamsungTvDevice {
  const SamsungTvDevice({
    required this.host,
    this.name = 'Samsung TV',
    this.token = '',
    this.tlsPin = '',
    this.macAddress = '',
    this.deviceId = '',
    this.model = '',
    this.location = 'other',
    this.secure = true,
  });

  final String host;
  final String name;
  final String token;
  final String tlsPin;
  final String macAddress;
  final String deviceId;
  final String model;
  final String location;
  final bool secure;

  SamsungTvDevice copyWith({
    String? host, String? name, String? token, String? tlsPin,
    String? macAddress, String? deviceId, String? model,
    String? location, bool? secure,
  }) => SamsungTvDevice(
    host: host ?? this.host, name: name ?? this.name,
    token: token ?? this.token, tlsPin: tlsPin ?? this.tlsPin,
    macAddress: macAddress ?? this.macAddress,
    deviceId: deviceId ?? this.deviceId, model: model ?? this.model,
    location: location ?? this.location, secure: secure ?? this.secure,
  );

  Map<String, Object> toJson() => {
    'host': host, 'name': name, 'token': token, 'tlsPin': tlsPin,
    'macAddress': macAddress, 'deviceId': deviceId, 'model': model,
    'location': location, 'secure': secure,
  };

  static SamsungTvDevice fromJson(Map<String, dynamic> value) =>
      SamsungTvDevice(
        host: value['host'] is String ? value['host'] as String : '',
        name: value['name'] is String ? value['name'] as String : 'Samsung TV',
        token: value['token'] is String ? value['token'] as String : '',
        tlsPin: value['tlsPin'] is String ? value['tlsPin'] as String : '',
        macAddress: value['macAddress'] is String
            ? value['macAddress'] as String : '',
        deviceId: value['deviceId'] is String
            ? value['deviceId'] as String : '',
        model: value['model'] is String ? value['model'] as String : '',
        location: value['location'] is String
            ? value['location'] as String : 'other',
        secure: value['secure'] != false,
      );
}

class SamsungTvStore {
  SamsungTvStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'taptether.samsung.tv.pairings.v1';
  final FlutterSecureStorage _storage;

  Future<List<SamsungTvDevice>> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded.whereType<Map>().map((entry) =>
        SamsungTvDevice.fromJson(Map<String, dynamic>.from(entry)))
        .where((tv) => isPrivateIPv4(tv.host) && tv.token.isNotEmpty)
        .take(20).toList();
  }

  Future<void> save(SamsungTvDevice device) async {
    if (!isPrivateIPv4(device.host) || device.token.isEmpty) {
      throw const FormatException('Invalid Samsung TV pairing');
    }
    final records = await read();
    final previous = records.where((item) =>
        item.host == device.host ||
        (item.deviceId.isNotEmpty && device.deviceId.isNotEmpty &&
            item.deviceId == device.deviceId) ||
        (item.macAddress.isNotEmpty && device.macAddress.isNotEmpty &&
            item.macAddress == device.macAddress));
    final older = previous.isEmpty ? null : previous.first;
    final merged = device.copyWith(
      name: older != null && device.name == 'Samsung TV'
          ? older.name : device.name,
      macAddress: device.macAddress.isEmpty
          ? (older?.macAddress ?? '') : device.macAddress,
      deviceId: device.deviceId.isEmpty
          ? (older?.deviceId ?? '') : device.deviceId,
      location: device.location == 'other'
          ? (older?.location ?? 'other') : device.location,
    );
    records.removeWhere((item) => item.host == merged.host ||
        (merged.deviceId.isNotEmpty &&
            item.deviceId == merged.deviceId) ||
        (merged.macAddress.isNotEmpty &&
            item.macAddress == merged.macAddress));
    records.insert(0, merged);
    await _storage.write(key: key, value: jsonEncode(
        records.take(20).map((device) => device.toJson()).toList()));
    AutomaticDeviceBackup.instance.requestSoon();
  }

  Future<void> remove(String host) async {
    final records = await read();
    records.removeWhere((item) => item.host == host);
    await _storage.write(key: key, value: jsonEncode(
        records.map((device) => device.toJson()).toList()));
    AutomaticDeviceBackup.instance.requestSoon();
  }
}

/// API /api/v2/ returns identifying vendor metadata. An open TCP port alone
/// does not count as a Samsung TV. No pairing request occurs in this call.
SamsungTvDevice? samsungDeviceFromInfo(
    String host, Map<String, dynamic> response) {
  final device = response['device'];
  if (device is! Map) return null;
  final kind = device['type']?.toString().toLowerCase() ?? '';
  final brand = response['name']?.toString().toLowerCase() ?? '';
  if (!kind.contains('samsung') &&
      !(kind.contains('smarttv') && brand.contains('samsung'))) {
    return null;
  }
  final id = (device['id'] ?? device['udn'] ?? device['duid'])
      ?.toString() ?? '';
  final mac = normalizeTvMac(
      (device['wifiMac'] ?? device['mac'] ?? '').toString()) ?? '';
  return SamsungTvDevice(
    host: host,
    model: (device['modelName'] ?? device['model'] ?? '').toString(),
    deviceId: id,
    macAddress: mac,
  );
}

Future<Map<String, dynamic>?> _samsungHttp(
    String host, String path, {String method = 'GET',
    Duration timeout = const Duration(milliseconds: 750)}) async {
  if (!isPrivateIPv4(host) || !path.startsWith('/api/v2/')) {
    return null;
  }
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final uri = Uri(scheme: 'http', host: host, port: 8001, path: path);
    final request = await client.openUrl(method, uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    if (method == 'POST') {
      // Samsung frequently returns HTTP 204 with no JSON after app launch.
      return {'accepted': true};
    }
    final body = await utf8.decoder.bind(response).join()
        .timeout(timeout);
    if (body.length > 32768) return null;
    final decoded = jsonDecode(body);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<SamsungTvDevice?> probeSamsungTv(String host, {
    Duration timeout = const Duration(milliseconds: 750)}) async {
  final info = await _samsungHttp(host, '/api/v2/', timeout: timeout);
  return info == null ? null : samsungDeviceFromInfo(host, info);
}

/// Only explicit user discovery probes the Wi-Fi range.
Future<List<SamsungTvDevice>> discoverSamsungTvs() async {
  final lan = await detectLanRange();
  if (lan == null) return [];
  final addresses = tvLanHosts(lan);
  final found = <String, SamsungTvDevice>{};
  var next = 0;
  Future<void> worker() async {
    while (next < addresses.length) {
      final address = addresses[next++];
      final tv = await probeSamsungTv(address,
          timeout: const Duration(milliseconds: 420));
      if (tv != null) found[address] = tv;
    }
  }
  await Future.wait(List.generate(28, (_) => worker()));
  return found.values.toList()..sort((a,b) => a.host.compareTo(b.host));
}

/// Only a known, approved Samsung remote channel may receive commands.
class SamsungTvClient implements TvRemoteController {
  SamsungTvClient(this.device);
  SamsungTvDevice device;
  WebSocket? _socket;
  String? _observedTlsPin;
  bool _secure = true;
  final Map<String, String> _appNames = {};
  final Map<String, bool> _appRunning = {};
  int _moveX = 0;
  int _moveY = 0;

  @override
  bool get connected => _socket?.readyState == WebSocket.open;
  @override
  bool get pointerIsRelative => false;
  String get transport => _secure ? 'Encrypted LAN' : 'Local LAN';

  /// Token is issued after Allow on the television. The certificate is
  /// TOFU-pinned on first pairing and checked on subsequent connections.
  Future<SamsungTvDevice> connect() async {
    if (!isPrivateIPv4(device.host)) {
      throw const FormatException('Use a private TV LAN IP address.');
    }
    final name = base64Encode(utf8.encode('TapTether'));
    final info = await probeSamsungTv(device.host);
    Object? lastError;
    for (final secure in [true, false]) {
      final port = secure ? 8002 : 8001;
      final uri = Uri(
        scheme: secure ? 'wss' : 'ws',
        host: device.host, port: port,
        path: '/api/v2/channels/samsung.remote.control',
        queryParameters: {
          'name': name,
          if (device.token.isNotEmpty) 'token': device.token,
        },
      );
      final client = secure ? HttpClient(
          context: SecurityContext(withTrustedRoots: false)) : null;
      if (client != null) {
        client.badCertificateCallback = (cert, host, certPort) {
          if (host != device.host || certPort != port) return false;
          final pin = sha256.convert(cert.der).toString().toUpperCase();
          _observedTlsPin = pin;
          return device.tlsPin.isEmpty ||
              device.tlsPin.toUpperCase() == pin;
        };
      }
      WebSocket? socket;
      try {
        socket = await WebSocket.connect(uri.toString(),
            customClient: client).timeout(const Duration(seconds: 4));
        final ready = Completer<Map<String, dynamic>>();
        final sub = socket.listen((message) {
          if (message is! String) return;
          try {
            final decoded = jsonDecode(message);
            if (decoded is! Map) return;
            if (decoded['event'] == 'ms.channel.connect') {
              if (!ready.isCompleted) {
                ready.complete(Map<String, dynamic>.from(decoded));
              }
            } else if (decoded['event'] == 'ms.channel.unauthorized' ||
                decoded['event'] == 'ms.error') {
              if (!ready.isCompleted) {
                ready.completeError(StateError(
                    'Approve TapTether on the Samsung TV.'));
              }
            }
          } catch (_) {}
        }, onDone: () {
          if (!ready.isCompleted) {
            ready.completeError(StateError('TV closed the pairing request.'));
          }
        }, onError: (Object error) {
          if (!ready.isCompleted) ready.completeError(error);
        });
        final answer = await ready.future
            .timeout(const Duration(seconds: 40));
        final data = answer['data'];
        final token = data is Map ? data['token']?.toString() : null;
        if (device.token.isEmpty && (token == null || token.isEmpty)) {
          throw StateError('TV did not return a reusable pairing token.');
        }
        if (device.tlsPin.isNotEmpty && secure &&
            _observedTlsPin?.toUpperCase() !=
                device.tlsPin.toUpperCase()) {
          throw StateError('TV certificate changed. Verify TV identity.');
        }
        _socket = socket;
        _secure = secure;
        socket.pingInterval = const Duration(seconds: 22);
        // Keep receiver subscription alive while this session is open.
        // Events not carrying pairing information need no persistence.
        unawaited(sub.asFuture<void>().catchError((Object _) {}));
        device = device.copyWith(
          token: token == null || token.isEmpty ? device.token : token,
          tlsPin: secure ? (_observedTlsPin ?? device.tlsPin) : '',
          secure: secure,
          macAddress: info?.macAddress.isNotEmpty == true
              ? info!.macAddress : device.macAddress,
          deviceId: info?.deviceId.isNotEmpty == true
              ? info!.deviceId : device.deviceId,
          model: info?.model.isNotEmpty == true
              ? info!.model : device.model,
        );
        return device;
      } catch (error) {
        lastError = error is Exception ? error : StateError('$error');
        await socket?.close();
        // A previously encrypted/pinned TV must never silently downgrade.
        if (secure && device.tlsPin.isNotEmpty) rethrow;
      } finally {
        client?.close(force: false);
      }
    }
    throw StateError(lastError?.toString() ??
        'Samsung Smart View remote is unavailable on this TV.');
  }

  void _send(Map<String, Object> params) {
    if (!connected) {
      throw StateError('Samsung TV is not connected.');
    }
    _socket!.add(jsonEncode({
      'method': 'ms.remote.control',
      'params': params,
    }));
  }

  static const _keys = <String, String>{
    'UP': 'KEY_UP', 'DOWN': 'KEY_DOWN',
    'LEFT': 'KEY_LEFT', 'RIGHT': 'KEY_RIGHT',
    'ENTER': 'KEY_ENTER', 'BACK': 'KEY_RETURN',
    'HOME': 'KEY_HOME',
    'PLAY': 'KEY_PLAY', 'PAUSE': 'KEY_PAUSE',
    'STOP': 'KEY_STOP', 'REWIND': 'KEY_REWIND',
    'FASTFORWARD': 'KEY_FF',
  };

  @override
  Future<void> button(String name) async {
    final key = _keys[name];
    if (key == null) {
      throw const FormatException('Unsupported Samsung remote key.');
    }
    _key(key);
  }

  void _key(String key) => _send({
    'Cmd': 'Click', 'DataOfCmd': key,
    'Option': 'false', 'TypeOfRemote': 'SendRemoteKey',
  });

  @override
  Future<void> pointerMove(int dx, int dy) async {
    // Samsung Smart View cursor support varies by firmware. Reliable
    // swipe-as-D-pad fallback works without inventing pointer capability.
    _moveX += dx;
    _moveY += dy;
    if (_moveX.abs() < 24 && _moveY.abs() < 24) return;
    if (_moveX.abs() >= _moveY.abs()) {
      _key(_moveX > 0 ? 'KEY_RIGHT' : 'KEY_LEFT');
    } else {
      _key(_moveY > 0 ? 'KEY_DOWN' : 'KEY_UP');
    }
    _moveX = 0;
    _moveY = 0;
  }

  @override
  Future<void> pointerClick() async => button('ENTER');

  @override
  Future<void> insertText(String text) async {
    if (text.isEmpty) return;
    if (text.length > 500) {
      throw const FormatException('TV text exceeds 500 characters.');
    }
    _send({
      'TypeOfRemote': 'SendInputString',
      'Cmd': base64Encode(utf8.encode(text)),
      'DataOfCmd': 'base64',
    });
  }

  @override
  Future<void> volumeUp() async => _key('KEY_VOLUP');
  @override
  Future<void> volumeDown() async => _key('KEY_VOLDOWN');
  @override
  Future<void> mute(bool muted) async => _key('KEY_MUTE');
  @override
  Future<void> channelUp() async => _key('KEY_CHUP');
  @override
  Future<void> channelDown() async => _key('KEY_CHDOWN');
  @override
  Future<void> powerOff() async => _key('KEY_POWER');

  /// App availability differs by model. Only show REST-verified catalog
  /// entries, never guess that a service was installed.
  static const knownApps = <String, String>{
    '111299001912': 'YouTube',
    '3201907018807': 'Netflix',
    '3201910019365': 'Prime Video',
    '3201901017640': 'Disney+',
    '3201807016597': 'Apple TV',
    'org.tizen.browser': 'Browser',
  };

  @override
  Future<List<({String id, String title})>> apps() async {
    if (_appNames.isNotEmpty) {
      return _appNames.entries.map((e) =>
          (id: e.key, title: e.value)).toList();
    }
    final result = <({String id, String title})>[];
    for (final entry in knownApps.entries) {
      final state = await _samsungHttp(device.host,
          '/api/v2/applications/${entry.key}',
          timeout: const Duration(milliseconds: 550));
      if (state != null && state['id']?.toString() == entry.key) {
        _appNames[entry.key] = entry.value;
        _appRunning[entry.key] = state['running'] == true;
        result.add((id: entry.key, title: entry.value));
      }
    }
    return result;
  }

  @override
  Future<void> launchApp(String appId) async {
    if (!connected || !_appNames.containsKey(appId)) {
      throw StateError('Choose an available Samsung TV app.');
    }
    final result = await _samsungHttp(
        device.host, '/api/v2/applications/$appId',
        method: 'POST', timeout: const Duration(seconds: 2));
    if (result == null) {
      throw StateError('This Samsung TV does not allow remote app launch.');
    }
  }

  @override
  Future<String?> foregroundApp() async {
    if (!connected || _appNames.isEmpty) return null;
    for (final appId in _appNames.keys) {
      final result = await _samsungHttp(device.host,
          '/api/v2/applications/$appId',
          timeout: const Duration(milliseconds: 450));
      if (result?['running'] == true) return appId;
    }
    return null;
  }

  @override
  Future<String?> currentChannel() async => null;
  @override
  Future<int?> volumeLevel() async => null;

  @override
  Future<void> disconnect() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }
}

Future<void> wakeSamsungTv(SamsungTvDevice device) =>
    wakeTvOnLan(device.host, device.macAddress);
