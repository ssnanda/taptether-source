import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'discovery.dart';
import 'lan_scan.dart';
import 'tv_remote_controller.dart';

/// LG webOS Second Screen (SSAP) client. No agent, root, or TV app needed.
/// LG requires explicit approval on the TV at initial registration.
class LgTvDevice {
  const LgTvDevice({
    required this.host,
    required this.name,
    this.clientKey = '',
    this.tlsPin = '',
    this.secure = true,
    this.macAddress = '',
    this.deviceUuid = '',
    this.location = 'other',
  });

  final String host;
  final String name;
  final String clientKey;
  final String tlsPin;
  final bool secure;
  // Stable identity is MAC/TV UUID, never the DHCP address alone.
  final String macAddress;
  final String deviceUuid;
  final String location;

  LgTvDevice copyWith({
    String? host, String? name, String? clientKey,
    String? tlsPin, bool? secure, String? macAddress,
    String? deviceUuid, String? location,
  }) => LgTvDevice(
    host: host ?? this.host, name: name ?? this.name,
    clientKey: clientKey ?? this.clientKey, tlsPin: tlsPin ?? this.tlsPin,
    secure: secure ?? this.secure,
    macAddress: macAddress ?? this.macAddress,
    deviceUuid: deviceUuid ?? this.deviceUuid,
    location: location ?? this.location,
  );

  Map<String, Object> toJson() => {
    'host': host,
    'name': name,
    'clientKey': clientKey,
    'tlsPin': tlsPin,
    'secure': secure,
    'macAddress': macAddress,
    'deviceUuid': deviceUuid,
    'location': location,
  };

  static LgTvDevice fromJson(Map<String, dynamic> json) => LgTvDevice(
    host: (json['host'] as String?) ?? '',
    name: (json['name'] as String?) ?? 'LG webOS TV',
    clientKey: (json['clientKey'] as String?) ?? '',
    tlsPin: (json['tlsPin'] as String?) ?? '',
    secure: json['secure'] != false,
    macAddress: (json['macAddress'] as String?) ?? '',
    deviceUuid: (json['deviceUuid'] as String?) ?? '',
    location: (json['location'] as String?) ?? 'other',
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
    final matching = all.where((saved) =>
        saved.host == device.host ||
        (device.deviceUuid.isNotEmpty &&
            saved.deviceUuid == device.deviceUuid) ||
        (device.macAddress.isNotEmpty &&
            saved.macAddress == device.macAddress) ||
        (device.tlsPin.isNotEmpty &&
            saved.tlsPin.toUpperCase() == device.tlsPin.toUpperCase()));
    final previous = matching.isEmpty ? null : matching.first;
    // Preserve user-entered nicknames, older keys and MAC/UUID metadata.
    final merged = device.copyWith(
      name: device.name == 'LG webOS TV' && previous != null
          ? previous.name : device.name,
      macAddress: device.macAddress.isEmpty
          ? (previous?.macAddress ?? '') : device.macAddress,
      deviceUuid: device.deviceUuid.isEmpty
          ? (previous?.deviceUuid ?? '') : device.deviceUuid,
      location: device.location == 'other'
          ? (previous?.location ?? 'other') : device.location,
    );
    all.removeWhere((saved) => saved.host == device.host ||
        (merged.deviceUuid.isNotEmpty &&
            saved.deviceUuid == merged.deviceUuid) ||
        (merged.macAddress.isNotEmpty &&
            saved.macAddress == merged.macAddress) ||
        (merged.tlsPin.isNotEmpty &&
            saved.tlsPin.toUpperCase() == merged.tlsPin.toUpperCase()));
    all.insert(0, merged);
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

String? canonicalLgMac(String raw) {
  final hex = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]{12}$').hasMatch(hex) ||
      hex == '000000000000' || hex == 'FFFFFFFFFFFF') {
    return null;
  }
  return List.generate(6, (index) =>
      hex.substring(index * 2, index * 2 + 2)).join(':');
}

/// Wake packets are limited to the current private LAN.
Future<void> wakeLgTv(LgTvDevice tv) async {
  final mac = canonicalLgMac(tv.macAddress);
  if (mac == null) {
    throw StateError('Add the TV MAC address before using Power On.');
  }
  final network = await detectLanRange();
  if (network == null || !lanRangeContains(network, tv.host)) {
    throw StateError('Connect to the TV Wi-Fi network to power it on.');
  }
  final raw = mac.replaceAll(':', '');
  final address = <int>[
    for (var i = 0; i < 12; i += 2)
      int.parse(raw.substring(i, i + 2), radix: 16),
  ];
  final packet = <int>[
    ...List.filled(6, 255),
    for (var i = 0; i < 16; i++) ...address,
  ];
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    socket.broadcastEnabled = true;
    final broadcast = InternetAddress(lanBroadcastAddress(network));
    for (var i = 0; i < 3; i++) {
      socket.send(packet, broadcast, 9);
    }
  } finally {
    socket.close();
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
  // The vendor's second-screen service is evidence of LG webOS.
  // A generic LG UPnP device, a hostname, or an open TCP port is not.
  final lines = response.toLowerCase().split(RegExp(r'\r?\n'));
  if (lines.isEmpty || !lines.first.startsWith('http/1.1 200')) {
    return false;
  }
  return lines.skip(1).any((line) {
    final separator = line.indexOf(':');
    if (separator < 1) {
      return false;
    }
    final header = line.substring(0, separator).trim();
    final value = line.substring(separator + 1).trim();
    return (header == 'st' || header == 'usn') &&
        value.contains('urn:lge-com:service:webos-second-screen:');
  });
}

/// LG SSAP hello identifies a webOS TV without requesting registration.
bool isLgHelloResponse(Object? message) {
  if (message is! Map || message['type'] != 'hello') {
    return false;
  }
  final payload = message['payload'];
  if (payload is! Map) {
    return false;
  }
  return payload['deviceType']?.toString().toLowerCase() == 'tv' &&
      payload['deviceOS']?.toString().toLowerCase() == 'webos';
}

/// An open TCP port is never proof of a TV. TLS verification is bypassed
/// only for this short read-only hello; pairing pins the TV certificate.
Future<LgTvDevice?> readLgWebOsHello(String host, {
  Duration connectTimeout = const Duration(milliseconds: 300),
  Duration replyTimeout = const Duration(seconds: 2),
}) async {
  if (!validLgHost(host)) {
    return null;
  }
  for (final port in [3001, 3000]) {
    try {
      final tcp = await Socket.connect(host, port, timeout: connectTimeout);
      tcp.destroy();
    } on SocketException {
      continue;
    } on TimeoutException {
      continue;
    }

    WebSocket? ws;
    HttpClient? client;
    try {
      final secure = port == 3001;
      if (secure) {
        client = HttpClient(context: SecurityContext(withTrustedRoots: false));
        client.badCertificateCallback = (_, certificateHost, certificatePort) =>
            certificateHost == host && certificatePort == port;
      }
      final endpoint = Uri(scheme: secure ? 'wss' : 'ws',
          host: host, port: port);
      ws = await WebSocket.connect(endpoint.toString(),
          customClient: client).timeout(replyTimeout);
      ws.add(jsonEncode({'id': 'hello', 'type': 'hello', 'payload': {}}));
      final answer = await ws.first.timeout(replyTimeout);
      if (answer is String) {
        final parsed = jsonDecode(answer);
        if (isLgHelloResponse(parsed)) {
          final payload = parsed['payload'] as Map;
          return LgTvDevice(host: host, name: 'LG webOS TV',
              deviceUuid: payload['deviceUUID']?.toString() ?? '');
        }
      }
    } catch (_) {
      // Non-LG services, bad TLS, and timeouts are not TV matches.
    } finally {
      if (ws != null) {
        try {
          await ws.close().timeout(const Duration(milliseconds: 400));
        } catch (_) {
          // The read-only probe is finished even if the peer won't close.
        }
      }
      client?.close(force: true);
    }
  }
  return null;
}

Future<bool> probeLgWebOsHello(String host, {
  Duration connectTimeout = const Duration(milliseconds: 300),
  Duration replyTimeout = const Duration(seconds: 2),
}) async => (await readLgWebOsHello(host,
    connectTimeout: connectTimeout, replyTimeout: replyTimeout)) != null;

/// Verifies a previously paired LG TV by its pinned TLS certificate
/// without sending a registration request or displaying a pairing prompt.
Future<bool> matchesLgTlsPin(String host, String expectedPin) async {
  if (!validLgHost(host) ||
      !RegExp(r'^[0-9a-fA-F]{64}
List<String> lgDiscoveryHosts(DetectedLanRange network, {
  int maxAddresses = 1024,
}) {
  final prefixes = [
    network.activePrefix,
    ...network.scanPrefixes.where((p) => p != network.activePrefix),
  ];
  final networkAddress = network.cidr.split('/').first;
  final mask = network.subnetMask.split('.').map(int.parse).toList();
  final ip = network.ip.split('.').map(int.parse).toList();
  final broadcast = List.generate(4,
      (i) => ip[i] | (255 ^ mask[i])).join('.');
  final hosts = <String>[];
  for (final prefix in prefixes) {
    for (var suffix = 0; suffix <= 255; suffix++) {
      final host = '$prefix.$suffix';
      if (host == networkAddress || host == broadcast || host == network.ip ||
          !lanRangeContains(network, host)) {
        continue;
      }
      hosts.add(host);
      if (hosts.length >= maxAddresses) {
        return hosts;
      }
    }
  }
  return hosts;
}

/// A short, on-demand SSDP query. Does not require broad LAN scanning.
/// Multicast can be blocked by iOS/router permissions; manual IP still works.
Future<List<LgTvDevice>> discoverLgTvs({
  Duration timeout = const Duration(seconds: 2),
}) async {
  final range = await detectLanRange();
  if (range == null) return [];
  final found = <String, LgTvDevice>{};
  RawDatagramSocket? socket;
  StreamSubscription<RawSocketEvent>? sub;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sub = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      Datagram? data;
      while ((data = socket!.receive()) != null) {
        final host = data!.address.address;
        if (!validLgHost(host) || !lanRangeContains(range, host)) {
          continue;
        }
        final text = latin1.decode(data.data, allowInvalid: true);
        if (isLgSsdpResponse(text)) {
          found[host] = LgTvDevice(host: host, name: 'LG webOS TV');
        }
      }
    });
    final request = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 1\r\n'
        'ST: urn:lge-com:service:webos-second-screen:1\r\n\r\n';
    socket.send(utf8.encode(request),
        InternetAddress('239.255.255.250'), 1900);
    await Future<void>.delayed(timeout);
  } on SocketException {
    // iOS can block UDP multicast. Continue to verified SSAP hello below.
  } finally {
    await sub?.cancel();
    socket?.close();
  }
  // When multicast is unavailable, a manual tap triggers a bounded,
  // read-only SSAP hello check on the phone's current Wi-Fi CIDR.
  // A TCP or WebSocket connection alone is not a TV match.
  if (found.isEmpty) {
    final hosts = lgDiscoveryHosts(range);
    var next = 0;
    Future<void> worker() async {
      while (next < hosts.length) {
        final host = hosts[next++];
        final tv = await readLgWebOsHello(host);
        if (tv != null) {
          found[host] = tv;
        }
      }
    }
    await Future.wait(List.generate(24, (_) => worker()));
  }
  return found.values.toList()..sort((a, b) => a.host.compareTo(b.host));
}

class LgWebOsClient implements TvRemoteController {
  LgWebOsClient(this.device);
  final LgTvDevice device;
  @override
  bool get pointerIsRelative => true;
  WebSocket? _main;
  WebSocket? _pointer;
  Future<void>? _pointerOpening;
  StreamSubscription<dynamic>? _mainSubscription;
  final Map<String, Completer<Map<String, dynamic>>> _waiting = {};
  String? _registrationRequestId;
  int _id = 0;
  bool _pinMismatch = false;
  String? _observedPin;
  bool _secure = true;

  @override
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
          macAddress: device.macAddress,
          deviceUuid: device.deviceUuid,
          location: device.location,
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
      final kind = decoded['type']?.toString();
      final data = decoded['payload'];
      // Some LG models first acknowledge the registration request with
      // pairingType PROMPT, then send "registered" after TV approval.
      // Do not fail pairing when that intermediate acknowledgement arrives.
      if (_registrationRequestId != null &&
          kind == 'response' && data is Map &&
          data['pairingType'] is String) {
        return;
      }
      var id = decoded['id']?.toString();
      if ((kind == 'registered' || kind == 'error') &&
          _registrationRequestId != null &&
          (id == null || !_waiting.containsKey(id))) {
        id = _registrationRequestId;
      }
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
    _registrationRequestId = null;
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
    final registering = command['type'] == 'register';
    if (registering) {
      _registrationRequestId = id;
    }
    socket.add(jsonEncode({'id': id, ...command}));
    try {
      return await waiting.future.timeout(timeout);
    } finally {
      _waiting.remove(id);
      if (_registrationRequestId == id) {
        _registrationRequestId = null;
      }
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

  Future<void> _openPointer() async {
    if (_pointer?.readyState == WebSocket.open) return;
    if (_pointerOpening != null) return _pointerOpening!;
    Future<void> open() async {
      final payload = await request(
          'ssap://com.webos.service.networkinput/getPointerInputSocket');
      final socketPath = payload['socketPath'];
      if (socketPath is! String) {
        throw StateError('LG TV pointer input unavailable');
      }
      final uri = Uri.tryParse(socketPath);
      if (uri == null || !safeLgPointerUri(uri, device.host)) {
        throw StateError('TV returned an unsafe pointer endpoint');
      }
      // The authenticated TV chooses the separate pointer transport.
      // LG sometimes returns ws: even when the main SSAP channel is wss:.
      _pointer = await WebSocket.connect(uri.toString(),
        customClient: uri.scheme == 'wss' ? _httpsClient() : null,
      ).timeout(const Duration(seconds: 5));
    }
    _pointerOpening = open();
    try {
      await _pointerOpening;
    } finally {
      _pointerOpening = null;
    }
  }

  @override
  Future<void> button(String name) async {
    const allowed = {
      'UP', 'DOWN', 'LEFT', 'RIGHT', 'ENTER', 'BACK', 'HOME',
      'PLAY', 'PAUSE', 'STOP', 'REWIND', 'FASTFORWARD',
    };
    if (!allowed.contains(name)) {
      throw const FormatException('Unsupported TV remote key');
    }
    await _openPointer();
    _pointer!.add('type:button\nname:$name\n\n');
  }

  @override
  Future<void> pointerMove(int dx, int dy) async {
    if (dx == 0 && dy == 0) return;
    await _openPointer();
    final x = dx.clamp(-500, 500);
    final y = dy.clamp(-500, 500);
    _pointer!.add('type:move\ndx:$x\ndy:$y\ndown:0\n\n');
  }

  @override
  Future<void> pointerClick() async {
    await _openPointer();
    _pointer!.add('type:click\n\n');
  }

  @override
  Future<void> insertText(String text) async {
    if (text.isEmpty) return;
    if (text.length > 500) {
      throw const FormatException('Text is too long for TV input');
    }
    await request('ssap://com.webos.service.ime/insertText',
        {'text': text, 'replace': 0});
  }

  /// Identity metadata is gathered only over a paired control channel.
  Future<LgTvDevice> identify(LgTvDevice paired) async {
    var mac = paired.macAddress;
    var uuid = paired.deviceUuid;
    try {
      final payload = await request(
          'ssap://com.webos.service.connectionmanager/getinfo');
      String? readMac(Object? item) {
        if (item is Map && item['macAddress'] is String) {
          return canonicalLgMac(item['macAddress'] as String);
        }
        return null;
      }
      mac = readMac(payload['wifiInfo']) ??
          readMac(payload['wiredInfo']) ?? mac;
    } catch (_) {
      // Older firmware may not expose network details.
    }
    try {
      final result = await _send({'type': 'hello'},
          timeout: const Duration(seconds: 3));
      final payload = result['payload'];
      if (payload is Map && payload['deviceUUID'] is String) {
        uuid = payload['deviceUUID'] as String;
      }
    } catch (_) {
      // Optional hello is not universally available after registration.
    }
    return paired.copyWith(macAddress: mac, deviceUuid: uuid);
  }

  @override
  Future<String?> foregroundApp() async {
    final payload = await request(
        'ssap://com.webos.applicationManager/getForegroundAppInfo');
    return payload['appId']?.toString();
  }

  @override
  Future<String?> currentChannel() async {
    final payload = await request('ssap://tv/getCurrentChannel');
    final number = payload['channelNumber']?.toString() ??
        payload['majorNumber']?.toString();
    final name = payload['channelName']?.toString();
    if (number == null && name == null) return null;
    return [number, name].whereType<String>()
        .where((value) => value.isNotEmpty).join(' · ');
  }

  @override
  Future<int?> volumeLevel() async {
    final payload = await request('ssap://audio/getVolume');
    final number = payload['volume'];
    return number is num && number >= 0 ? number.round() : null;
  }

  @override
  Future<void> volumeUp() async { await request('ssap://audio/volumeUp'); }
  @override
  Future<void> volumeDown() async { await request('ssap://audio/volumeDown'); }
  @override
  Future<void> mute(bool value) async {
    await request('ssap://audio/setMute', {'mute': value});
  }
  @override
  Future<void> channelUp() async { await request('ssap://tv/channelUp'); }
  @override
  Future<void> channelDown() async { await request('ssap://tv/channelDown'); }
  @override
  Future<void> powerOff() async { await request('ssap://system/turnOff'); }

  @override
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

  @override
  Future<void> launchApp(String appId) async {
    if (appId.isEmpty || appId.length > 128) {
      throw const FormatException('Invalid TV application');
    }
    await request('ssap://com.webos.applicationManager/launch', {'id': appId});
  }

  @override
  Future<void> disconnect() async {
    _closed(StateError('LG TV session closed'));
    await _mainSubscription?.cancel();
    _mainSubscription = null;
    await _pointer?.close();
    _pointer = null;
    _pointerOpening = null;
    await _main?.close();
    _main = null;
  }
}
).hasMatch(expectedPin)) {
    return false;
  }
  final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false));
  var same = false;
  client.badCertificateCallback = (cert, certificateHost, port) {
    if (certificateHost != host || port != 3001) {
      return false;
    }
    same = sha256.convert(cert.der).toString().toUpperCase() ==
        expectedPin.toUpperCase();
    return same;
  };
  WebSocket? connection;
  try {
    connection = await WebSocket.connect('wss://$host:3001',
        customClient: client).timeout(const Duration(seconds: 2));
    return same;
  } catch (_) {
    return false;
  } finally {
    try {
      await connection?.close().timeout(const Duration(milliseconds: 350));
    } catch (_) {}
    client.close(force: true);
  }
}

/// Prioritize the phone's /24 while respecting the entire current Wi-Fi CIDR.
List<String> lgDiscoveryHosts(DetectedLanRange network, {
  int maxAddresses = 1024,
}) {
  final prefixes = [
    network.activePrefix,
    ...network.scanPrefixes.where((p) => p != network.activePrefix),
  ];
  final networkAddress = network.cidr.split('/').first;
  final mask = network.subnetMask.split('.').map(int.parse).toList();
  final ip = network.ip.split('.').map(int.parse).toList();
  final broadcast = List.generate(4,
      (i) => ip[i] | (255 ^ mask[i])).join('.');
  final hosts = <String>[];
  for (final prefix in prefixes) {
    for (var suffix = 0; suffix <= 255; suffix++) {
      final host = '$prefix.$suffix';
      if (host == networkAddress || host == broadcast || host == network.ip ||
          !lanRangeContains(network, host)) {
        continue;
      }
      hosts.add(host);
      if (hosts.length >= maxAddresses) {
        return hosts;
      }
    }
  }
  return hosts;
}

/// A short, on-demand SSDP query. Does not require broad LAN scanning.
/// Multicast can be blocked by iOS/router permissions; manual IP still works.
Future<List<LgTvDevice>> discoverLgTvs({
  Duration timeout = const Duration(seconds: 2),
}) async {
  final range = await detectLanRange();
  if (range == null) return [];
  final found = <String, LgTvDevice>{};
  RawDatagramSocket? socket;
  StreamSubscription<RawSocketEvent>? sub;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sub = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      Datagram? data;
      while ((data = socket!.receive()) != null) {
        final host = data!.address.address;
        if (!validLgHost(host) || !lanRangeContains(range, host)) {
          continue;
        }
        final text = latin1.decode(data.data, allowInvalid: true);
        if (isLgSsdpResponse(text)) {
          found[host] = LgTvDevice(host: host, name: 'LG webOS TV');
        }
      }
    });
    final request = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 1\r\n'
        'ST: urn:lge-com:service:webos-second-screen:1\r\n\r\n';
    socket.send(utf8.encode(request),
        InternetAddress('239.255.255.250'), 1900);
    await Future<void>.delayed(timeout);
  } on SocketException {
    // iOS can block UDP multicast. Continue to verified SSAP hello below.
  } finally {
    await sub?.cancel();
    socket?.close();
  }
  // When multicast is unavailable, a manual tap triggers a bounded,
  // read-only SSAP hello check on the phone's current Wi-Fi CIDR.
  // A TCP or WebSocket connection alone is not a TV match.
  if (found.isEmpty) {
    final hosts = lgDiscoveryHosts(range);
    var next = 0;
    Future<void> worker() async {
      while (next < hosts.length) {
        final host = hosts[next++];
        final tv = await readLgWebOsHello(host);
        if (tv != null) {
          found[host] = tv;
        }
      }
    }
    await Future.wait(List.generate(24, (_) => worker()));
  }
  return found.values.toList()..sort((a, b) => a.host.compareTo(b.host));
}

class LgWebOsClient implements TvRemoteController {
  LgWebOsClient(this.device);
  final LgTvDevice device;
  @override
  bool get pointerIsRelative => true;
  WebSocket? _main;
  WebSocket? _pointer;
  Future<void>? _pointerOpening;
  StreamSubscription<dynamic>? _mainSubscription;
  final Map<String, Completer<Map<String, dynamic>>> _waiting = {};
  String? _registrationRequestId;
  int _id = 0;
  bool _pinMismatch = false;
  String? _observedPin;
  bool _secure = true;

  @override
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
          macAddress: device.macAddress,
          deviceUuid: device.deviceUuid,
          location: device.location,
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
      final kind = decoded['type']?.toString();
      final data = decoded['payload'];
      // Some LG models first acknowledge the registration request with
      // pairingType PROMPT, then send "registered" after TV approval.
      // Do not fail pairing when that intermediate acknowledgement arrives.
      if (_registrationRequestId != null &&
          kind == 'response' && data is Map &&
          data['pairingType'] is String) {
        return;
      }
      var id = decoded['id']?.toString();
      if ((kind == 'registered' || kind == 'error') &&
          _registrationRequestId != null &&
          (id == null || !_waiting.containsKey(id))) {
        id = _registrationRequestId;
      }
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
    _registrationRequestId = null;
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
    final registering = command['type'] == 'register';
    if (registering) {
      _registrationRequestId = id;
    }
    socket.add(jsonEncode({'id': id, ...command}));
    try {
      return await waiting.future.timeout(timeout);
    } finally {
      _waiting.remove(id);
      if (_registrationRequestId == id) {
        _registrationRequestId = null;
      }
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

  Future<void> _openPointer() async {
    if (_pointer?.readyState == WebSocket.open) return;
    if (_pointerOpening != null) return _pointerOpening!;
    Future<void> open() async {
      final payload = await request(
          'ssap://com.webos.service.networkinput/getPointerInputSocket');
      final socketPath = payload['socketPath'];
      if (socketPath is! String) {
        throw StateError('LG TV pointer input unavailable');
      }
      final uri = Uri.tryParse(socketPath);
      if (uri == null || !safeLgPointerUri(uri, device.host)) {
        throw StateError('TV returned an unsafe pointer endpoint');
      }
      // The authenticated TV chooses the separate pointer transport.
      // LG sometimes returns ws: even when the main SSAP channel is wss:.
      _pointer = await WebSocket.connect(uri.toString(),
        customClient: uri.scheme == 'wss' ? _httpsClient() : null,
      ).timeout(const Duration(seconds: 5));
    }
    _pointerOpening = open();
    try {
      await _pointerOpening;
    } finally {
      _pointerOpening = null;
    }
  }

  @override
  Future<void> button(String name) async {
    const allowed = {
      'UP', 'DOWN', 'LEFT', 'RIGHT', 'ENTER', 'BACK', 'HOME',
      'PLAY', 'PAUSE', 'STOP', 'REWIND', 'FASTFORWARD',
    };
    if (!allowed.contains(name)) {
      throw const FormatException('Unsupported TV remote key');
    }
    await _openPointer();
    _pointer!.add('type:button\nname:$name\n\n');
  }

  @override
  Future<void> pointerMove(int dx, int dy) async {
    if (dx == 0 && dy == 0) return;
    await _openPointer();
    final x = dx.clamp(-500, 500);
    final y = dy.clamp(-500, 500);
    _pointer!.add('type:move\ndx:$x\ndy:$y\ndown:0\n\n');
  }

  @override
  Future<void> pointerClick() async {
    await _openPointer();
    _pointer!.add('type:click\n\n');
  }

  @override
  Future<void> insertText(String text) async {
    if (text.isEmpty) return;
    if (text.length > 500) {
      throw const FormatException('Text is too long for TV input');
    }
    await request('ssap://com.webos.service.ime/insertText',
        {'text': text, 'replace': 0});
  }

  /// Identity metadata is gathered only over a paired control channel.
  Future<LgTvDevice> identify(LgTvDevice paired) async {
    var mac = paired.macAddress;
    var uuid = paired.deviceUuid;
    try {
      final payload = await request(
          'ssap://com.webos.service.connectionmanager/getinfo');
      String? readMac(Object? item) {
        if (item is Map && item['macAddress'] is String) {
          return canonicalLgMac(item['macAddress'] as String);
        }
        return null;
      }
      mac = readMac(payload['wifiInfo']) ??
          readMac(payload['wiredInfo']) ?? mac;
    } catch (_) {
      // Older firmware may not expose network details.
    }
    try {
      final result = await _send({'type': 'hello'},
          timeout: const Duration(seconds: 3));
      final payload = result['payload'];
      if (payload is Map && payload['deviceUUID'] is String) {
        uuid = payload['deviceUUID'] as String;
      }
    } catch (_) {
      // Optional hello is not universally available after registration.
    }
    return paired.copyWith(macAddress: mac, deviceUuid: uuid);
  }

  @override
  Future<String?> foregroundApp() async {
    final payload = await request(
        'ssap://com.webos.applicationManager/getForegroundAppInfo');
    return payload['appId']?.toString();
  }

  @override
  Future<String?> currentChannel() async {
    final payload = await request('ssap://tv/getCurrentChannel');
    final number = payload['channelNumber']?.toString() ??
        payload['majorNumber']?.toString();
    final name = payload['channelName']?.toString();
    if (number == null && name == null) return null;
    return [number, name].whereType<String>()
        .where((value) => value.isNotEmpty).join(' · ');
  }

  @override
  Future<int?> volumeLevel() async {
    final payload = await request('ssap://audio/getVolume');
    final number = payload['volume'];
    return number is num && number >= 0 ? number.round() : null;
  }

  @override
  Future<void> volumeUp() async { await request('ssap://audio/volumeUp'); }
  @override
  Future<void> volumeDown() async { await request('ssap://audio/volumeDown'); }
  @override
  Future<void> mute(bool value) async {
    await request('ssap://audio/setMute', {'mute': value});
  }
  @override
  Future<void> channelUp() async { await request('ssap://tv/channelUp'); }
  @override
  Future<void> channelDown() async { await request('ssap://tv/channelDown'); }
  @override
  Future<void> powerOff() async { await request('ssap://system/turnOff'); }

  @override
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

  @override
  Future<void> launchApp(String appId) async {
    if (appId.isEmpty || appId.length > 128) {
      throw const FormatException('Invalid TV application');
    }
    await request('ssap://com.webos.applicationManager/launch', {'id': appId});
  }

  @override
  Future<void> disconnect() async {
    _closed(StateError('LG TV session closed'));
    await _mainSubscription?.cancel();
    _mainSubscription = null;
    await _pointer?.close();
    _pointer = null;
    _pointerOpening = null;
    await _main?.close();
    _main = null;
  }
}
