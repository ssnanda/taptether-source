import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'discovery.dart';
import 'lan_scan.dart';

/// LG webOS Second Screen (SSAP) client. No agent, root, or TV app needed.
/// LG requires explicit approval on the TV at initial registration.
class LgTvDevice {
  const LgTvDevice({
    required this.host,
    required this.name,
    this.clientKey = '',
    this.tlsPin = '',
    this.secure = true,
  });

  final String host;
  final String name;
  final String clientKey;
  final String tlsPin;
  final bool secure;

  Map<String, Object> toJson() => {
    'host': host,
    'name': name,
    'clientKey': clientKey,
    'tlsPin': tlsPin,
    'secure': secure,
  };

  static LgTvDevice fromJson(Map<String, dynamic> json) => LgTvDevice(
    host: (json['host'] as String?) ?? '',
    name: (json['name'] as String?) ?? 'LG webOS TV',
    clientKey: (json['clientKey'] as String?) ?? '',
    tlsPin: (json['tlsPin'] as String?) ?? '',
    secure: json['secure'] != false,
  );
}

class LgTvStore {
  LgTvStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'taptether.lg.webos.pairings.v1';
  final FlutterSecureStorage _storage;

  Future<List<LgTvDevice>> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return [];
    final data = jsonDecode(raw);
    if (data is! List) return [];
    return data.whereType<Map>().map((item) =>
        LgTvDevice.fromJson(Map<String, dynamic>.from(item)))
        .where((tv) => validLgHost(tv.host) && tv.clientKey.isNotEmpty)
        .take(20).toList();
  }

  Future<void> save(LgTvDevice device) async {
    if (!validLgHost(device.host) || device.clientKey.isEmpty) {
      throw const FormatException('Invalid LG TV pairing details');
    }
    final all = await read();
    all.removeWhere((saved) => saved.host == device.host);
    all.insert(0, device);
    await _storage.write(
      key: key,
      value: jsonEncode(all.take(20).map((tv) => tv.toJson()).toList()),
    );
  }

  Future<void> remove(String host) async {
    final all = await read();
    all.removeWhere((tv) => tv.host == host);
    await _storage.write(key: key, value: jsonEncode(
      all.map((tv) => tv.toJson()).toList(),
    ));
  }
}

bool validLgHost(String host) => isPrivateIPv4(host.trim());

/// Only accept a pointer endpoint on the same TV; never follow arbitrary
/// URLs returned by an unauthenticated or compromised LAN endpoint.
bool safeLgPointerUri(Uri uri, String host) =>
    (uri.scheme == 'ws' || uri.scheme == 'wss') &&
    uri.host == host && uri.port > 0 && uri.port <= 65535 &&
    uri.userInfo.isEmpty && uri.fragment.isEmpty;

bool isLgSsdpResponse(String response) {
  final message = response.toLowerCase();
  return message.contains('webos-second-screen') ||
      message.contains('urn:lge-com:service') ||
      (message.contains('webos') && message.contains('location:'));
}

/// A short, on-demand SSDP query. Does not require broad LAN scanning.
/// Multicast can be blocked by iOS/router permissions; manual IP still works.
Future<List<LgTvDevice>> discoverLgTvs({
  Duration timeout = const Duration(seconds: 2),
}) async {
  final range = await detectLanRange();
  if (range == null) return [];
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final found = <String, LgTvDevice>{};
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    Datagram? data;
    while ((data = socket.receive()) != null) {
      final host = data!.address.address;
      if (!validLgHost(host) || !lanRangeContains(range, host)) continue;
      final text = latin1.decode(data.data, allowInvalid: true);
      if (isLgSsdpResponse(text)) {
        found[host] = LgTvDevice(host: host, name: 'LG webOS TV');
      }
    }
  });
  try {
    final request = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 1\r\n'
        'ST: urn:lge-com:service:webos-second-screen:1\r\n\r\n';
    socket.send(utf8.encode(request),
        InternetAddress('239.255.255.250'), 1900);
    await Future<void>.delayed(timeout);
  } finally {
    await sub.cancel();
    socket.close();
  }
  // iOS and some routers block SSDP multicast. A tap-initiated scan checks
  // ONLY the current Wi-Fi /24, at most 12 connections at once, never
  // background-scanning unrelated network adapters or internet addresses.
  if (found.isEmpty) {
    final prefix = range.activePrefix;
    var next = 1;
    Future<void> worker() async {
      while (next <= 254) {
        final suffix = next++;
        final host = '$prefix.$suffix';
        if (!lanRangeContains(range, host) || host == range.ip) continue;
        for (final port in [3001, 3000]) {
          try {
            final socket = await Socket.connect(
              host, port,
              timeout: const Duration(milliseconds: 250),
            );
            socket.destroy();
            found[host] = LgTvDevice(
              host: host,
              name: 'Possible LG webOS TV',
            );
            break;
          } on SocketException {
            // Not a TV candidate on this port.
          } on TimeoutException {
            // Unreachable TV or no responder.
          }
        }
      }
    }
    await Future.wait(List.generate(12, (_) => worker()));
  }
  return found.values.toList()..sort((a, b) => a.host.compareTo(b.host));
}

class LgWebOsClient {
  LgWebOsClient(this.device);
  final LgTvDevice device;
  WebSocket? _main;
  WebSocket? _pointer;
  StreamSubscription<dynamic>? _mainSubscription;
  final Map<String, Completer<Map<String, dynamic>>> _waiting = {};
  int _id = 0;
  bool _pinMismatch = false;
  String? _observedPin;
  bool _secure = true;

  bool get connected => _main?.readyState == WebSocket.open;
  String get transport => _secure ? 'Encrypted LAN' : 'Legacy LAN';

  static const permissions = <String>[
    'LAUNCH', 'LAUNCH_WEBAPP', 'CLOSE', 'CONTROL_AUDIO',
    'CONTROL_POWER', 'CONTROL_MOUSE_AND_KEYBOARD',
    'CONTROL_INPUT_TEXT', 'CONTROL_INPUT_MEDIA_PLAYBACK',
    'CONTROL_INPUT_TV', 'READ_RUNNING_APPS', 'READ_INSTALLED_APPS',
    'READ_INPUT_DEVICE_LIST', 'READ_CURRENT_CHANNEL',
  ];

  /// webOS 26 rejects some old signed manifests. Use an unsigned manifest
  /// with explicitly scoped remote-control permissions.
  Map<String, Object> registration() => {
    'forcePairing': false,
    'pairingType': 'PROMPT',
    'manifest': {
      'manifestVersion': 1,
      'appVersion': '1.0',
      'permissions': permissions,
    },
    if (device.clientKey.isNotEmpty) 'client-key': device.clientKey,
  };

  HttpClient _httpsClient() {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.connectionTimeout = const Duration(seconds: 3);
    client.badCertificateCallback = (cert, host, port) {
      if (host != device.host) return false;
      final pem = cert.pem
          .replaceAll('-----BEGIN CERTIFICATE-----', '')
          .replaceAll('-----END CERTIFICATE-----', '')
          .replaceAll(RegExp(r'\s+'), '');
      final fingerprint = sha256.convert(base64Decode(pem))
          .toString().toUpperCase();
      final expected = device.tlsPin.toUpperCase();
      if (expected.isNotEmpty && expected != fingerprint) {
        _pinMismatch = true;
        return false;
      }
      _observedPin = fingerprint;
      return true;
    };
    return client;
  }

  Future<LgTvDevice> connect() async {
    if (!validLgHost(device.host)) {
      throw const FormatException('LG TV must use a private LAN IPv4 address');
    }
    // Never allow a TLS-pinned TV to downgrade silently to plaintext.
    final endpoints = device.tlsPin.isNotEmpty
        ? ['wss://${device.host}:3001']
        : ['wss://${device.host}:3001', 'ws://${device.host}:3000'];
    Object? failure;
    for (final endpoint in endpoints) {
      try {
        _secure = endpoint.startsWith('wss:');
        _observedPin = null;
        final client = _secure ? _httpsClient() : null;
        _main = await WebSocket.connect(endpoint,
            customClient: client).timeout(const Duration(seconds: 4));
        _mainSubscription = _main!.listen(_receive, onError: _closed,
            onDone: () => _closed(StateError('LG TV disconnected')));
        final response = await _send({
          'type': 'register',
          'payload': registration(),
        }, timeout: const Duration(seconds: 45));
        final payload = response['payload'];
        final key = payload is Map ? payload['client-key'] : null;
        if (response['type'] != 'registered' || key is! String || key.isEmpty) {
          throw StateError('Pairing was not approved on the LG TV');
        }
        return LgTvDevice(
          host: device.host,
          name: device.name,
          clientKey: key,
          tlsPin: _secure ? (_observedPin ?? '') : '',
          secure: _secure,
        );
      } catch (e) {
        failure = e;
        await disconnect();
        if (_pinMismatch) {
          throw StateError('LG TV TLS identity changed. Pair again explicitly.');
        }
        // Pairing refusal is not a reason to open a weaker protocol.
        if (e is StateError && e.message.toString().contains('Pairing')) rethrow;
      }
    }
    throw StateError('Cannot connect to LG TV at ${device.host}: $failure');
  }

  void _receive(dynamic raw) {
    try {
      if (raw is! String) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final id = decoded['id']?.toString();
      final pending = _waiting.remove(id);
      if (pending != null && !pending.isCompleted) {
        pending.complete(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Ignore malformed unsolicited TV events.
    }
  }

  void _closed(Object? error) {
    for (final completer in _waiting.values) {
      if (!completer.isCompleted) {
        completer.completeError(error ?? StateError('LG TV disconnected'));
      }
    }
    _waiting.clear();
  }

  Future<Map<String, dynamic>> _send(Map<String, Object> command, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final socket = _main;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('LG TV is not connected');
    }
    final id = 'tt-${++_id}';
    final waiting = Completer<Map<String, dynamic>>();
    _waiting[id] = waiting;
    socket.add(jsonEncode({'id': id, ...command}));
    try {
      return await waiting.future.timeout(timeout);
    } finally {
      _waiting.remove(id);
    }
  }

  Future<Map<String, dynamic>> request(String uri, [
    Map<String, Object> payload = const {},
  ]) async {
    final response = await _send({
      'type': 'request',
      'uri': uri,
      if (payload.isNotEmpty) 'payload': payload,
    });
    final result = response['payload'];
    if (response['type'] == 'error' ||
        (result is Map && result['returnValue'] == false)) {
      throw StateError('LG TV rejected ${uri.split('/').last}: '
          '${response['error'] ?? (result is Map ? result['errorText'] : null) ?? 'unsupported'}');
    }
    return result is Map ? Map<String, dynamic>.from(result) : {};
  }

  Future<void> button(String name) async {
    const allowed = {
      'UP', 'DOWN', 'LEFT', 'RIGHT', 'ENTER', 'BACK', 'HOME',
      'PLAY', 'PAUSE', 'STOP', 'REWIND', 'FASTFORWARD',
    };
    if (!allowed.contains(name)) {
      throw const FormatException('Unsupported TV remote key');
    }
    if (_pointer == null || _pointer!.readyState != WebSocket.open) {
      final payload = await request(
          'ssap://com.webos.service.networkinput/getPointerInputSocket');
      final socketPath = payload['socketPath'];
      if (socketPath is! String) {
        throw StateError('LG TV pointer control unavailable');
      }
      final uri = Uri.tryParse(socketPath);
      if (uri == null || !safeLgPointerUri(uri, device.host)) {
        throw StateError('LG TV returned an unsafe pointer endpoint');
      }
      if (device.tlsPin.isNotEmpty && uri.scheme != 'wss') {
        throw StateError('TV pointer connection cannot downgrade encryption');
      }
      _pointer = await WebSocket.connect(uri.toString(),
          customClient: uri.scheme == 'wss' ? _httpsClient() : null)
          .timeout(const Duration(seconds: 5));
    }
    _pointer!.add('type:button\nname:$name\n\n');
  }

  Future<void> volumeUp() async { await request('ssap://audio/volumeUp'); }
  Future<void> volumeDown() async { await request('ssap://audio/volumeDown'); }
  Future<void> mute(bool value) async {
    await request('ssap://audio/setMute', {'mute': value});
  }
  Future<void> channelUp() async { await request('ssap://tv/channelUp'); }
  Future<void> channelDown() async { await request('ssap://tv/channelDown'); }
  Future<void> powerOff() async { await request('ssap://system/turnOff'); }

  Future<List<({String id, String title})>> apps() async {
    final payload = await request(
        'ssap://com.webos.applicationManager/listLaunchPoints');
    final points = payload['launchPoints'];
    if (points is! List) return [];
    return points.whereType<Map>().where((item) =>
        item['id'] is String && item['title'] is String)
        .map((item) => (
          id: item['id'] as String,
          title: item['title'] as String,
        )).take(100).toList()
      ..sort((a, b) => a.title.compareTo(b.title));
  }

  Future<void> launchApp(String appId) async {
    if (appId.isEmpty || appId.length > 128) {
      throw const FormatException('Invalid TV application');
    }
    await request('ssap://com.webos.applicationManager/launch', {'id': appId});
  }

  Future<void> disconnect() async {
    _closed(StateError('LG TV session closed'));
    await _mainSubscription?.cancel();
    _mainSubscription = null;
    await _pointer?.close();
    _pointer = null;
    await _main?.close();
    _main = null;
  }
}
