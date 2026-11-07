import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// Local-only MAG254 / Infomir MAGic Remote service.
/// Protocol independently ported from MIT-licensed magic-remote.py by
/// Radoslav Gerganov: https://github.com/rgerganov/magic-remote.
/// The device settings' optional password is NOT used by this protocol.
/// Pairing requires the six-digit code displayed by the receiver.
class Mag254Protocol {
  static const int port = 40611;
  static const String deviceDescription = 'TapTether';
  static const _pair = 'pairing-reqpairing-reqpairing-re';
  static const _finishPair = 'pairing-complete-reqpairing-comp';
  static const _connect = 'connect-reqconnect-reqconnect-re';
  static const _ping = 'ping-reqping-reqping-reqping-req';
  static const _key = 'rc-code-reqrc-code-reqrc-code-re';

  static const _suffix = [8, 56, 158, 132, 29, 181, 211, 74];
  static const _iv = [
    18, 111, 241, 33, 102, 71, 144, 109,
    192, 233, 6, 153, 180, 99, 222, 101,
  ];

  static String newDeviceId() {
    final r = Random.secure();
    return List.generate(8,
        (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List crypt(String pairingCode, List<int> data,
      {required bool encrypt}) {
    if (!RegExp(r'^\d{6}$').hasMatch(pairingCode)) {
      throw const FormatException('Pairing requires a six-digit TV code.');
    }
    final digest = sha1.convert([
      ...utf8.encode(pairingCode),
      ..._suffix,
    ]).bytes;
    final aes = AESEngine()
      ..init(true, KeyParameter(Uint8List.fromList(digest.sublist(0, 16))));
    var feedback = Uint8List.fromList(_iv);
    final out = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += 16) {
      final stream = Uint8List(16);
      aes.processBlock(feedback, 0, stream, 0);
      final take = min(16, data.length - offset);
      for (var index = 0; index < take; index++) {
        out[offset + index] = data[offset + index] ^ stream[index];
      }
      if (take == 16) {
        feedback = Uint8List.fromList(
          encrypt ? out.sublist(offset, offset + 16)
              : data.sublist(offset, offset + 16),
        );
      }
    }
    return out;
  }

  static Uint8List message(
      String command, Map<String, dynamic> body, String? code) {
    if (ascii.encode(command).length != 32) {
      throw const FormatException('MAG command must be 32 ASCII bytes.');
    }
    final payload = utf8.encode(jsonEncode(body));
    final encrypted = code == null ? Uint8List.fromList(payload)
        : crypt(code, payload, encrypt: true);
    final length = 6 + 32 + encrypted.length;
    if (length > 255) {
      throw const FormatException('MAG control message is too long.');
    }
    return Uint8List.fromList([
      0, 0, 0, 1, length, 0,
      ...ascii.encode(command),
      ...encrypted,
    ]);
  }

  static Uint8List requestPair(String deviceId) =>
      message(_pair, {'dev_id': deviceId,
          'dev_descr': deviceDescription}, null);

  static Uint8List completePair(String deviceId, String code) =>
      message(_finishPair, {'dev_id': deviceId,
          'dev_descr': deviceDescription}, code);

  static Uint8List requestConnect(String deviceId) =>
      message(_connect, {'dev_id': deviceId,
          'dev_descr': deviceDescription}, null);

  static Uint8List ping(String deviceId, String code) =>
      message(_ping, {'dev_id': deviceId}, code);

  static Uint8List remoteKey(String deviceId, String code, int key) =>
      message(_key, {'dev_id': deviceId,
          'dev_descr': deviceDescription, 'rc_code': key}, code);

  static Map<String, dynamic> decodeReply(
      Uint8List frame, String pairingCode) {
    if (frame.length < 39 || frame[0] != 0 || frame[1] != 0 ||
        frame[2] != 0 || frame[3] != 1 ||
        frame[4] != frame.length) {
      throw const FormatException('Invalid MAG remote response.');
    }
    final plaintext = crypt(pairingCode, frame.sublist(38), encrypt: false);
    final result = jsonDecode(utf8.decode(plaintext));
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Invalid MAG response body.');
    }
    if (result['error'] != null || result['success'] == false ||
        result['status'] == 'error' || result['result'] == 'error') {
      throw const FormatException('MAG rejected the remote command.');
    }
    return result;
  }
}

class Mag254Keys {
  static const up = 189, down = 190, left = 191, right = 171, ok = 172;
  static const home = 141, back = 143, power = 140;
  static const volumeUp = 146, volumeDown = 147, mute = 176;
  static const channelUp = 188, channelDown = 145;
  static const info = 157, playPause = 139, rewind = 150, fastForward = 144;
  static const tv = 138, red = 178, green = 177, yellow = 185, blue = 186;
  static int digit(int value) {
    if (value < 0 || value > 9) {
      throw RangeError.range(value, 0, 9, 'digit');
    }
    return 128 + value;
  }
}

/// Incoming frame buffer: one TCP packet may contain partial or several frames.
class Mag254Frames {
  final _bytes = <int>[];
  List<Uint8List> feed(List<int> chunk) {
    _bytes.addAll(chunk);
    final frames = <Uint8List>[];
    while (_bytes.length >= 6) {
      if (_bytes[0] != 0 || _bytes[1] != 0 || _bytes[2] != 0 ||
          _bytes[3] != 1 || _bytes[4] < 38 || _bytes[5] != 0) {
        _bytes.clear();
        throw const FormatException('Invalid MAG remote frame.');
      }
      final size = _bytes[4];
      if (_bytes.length < size) break;
      frames.add(Uint8List.fromList(_bytes.sublist(0, size)));
      _bytes.removeRange(0, size);
    }
    return frames;
  }
}

/// Persistent direct TCP connection: no device agent or external server.
class Mag254Client {
  Mag254Client({required this.host, required this.deviceId,
      this.pairingCode});
  final String host;
  final String deviceId;
  final String? pairingCode;
  Socket? _socket;
  StreamSubscription<List<int>>? _events;
  final Mag254Frames _decoder = Mag254Frames();
  final Queue<Uint8List> _received = Queue();
  Completer<Uint8List>? _waiting;
  Future<void> _sequence = Future<void>.value();
  bool get connected => _socket != null;

  Future<void> open() async {
    if (_socket != null) return;
    _socket = await Socket.connect(host, Mag254Protocol.port,
        timeout: const Duration(seconds: 4));
    _events = _socket!.listen(
      (chunk) {
        try {
          for (final frame in _decoder.feed(chunk)) {
            if (_waiting != null && !_waiting!.isCompleted) {
              final pending = _waiting!;
              _waiting = null;
              pending.complete(frame);
            } else {
              _received.addLast(frame);
            }
          }
        } catch (error, stack) {
          _fail(error, stack);
        }
      },
      onError: (Object error, StackTrace trace) => _fail(error, trace),
      onDone: () => _fail(const SocketException('MAG disconnected')),
    );
  }

  void _fail(Object error, [StackTrace? stack]) {
    final pending = _waiting;
    _waiting = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error, stack);
    }
    _socket?.destroy();
    _socket = null;
  }

  Future<Uint8List> _next() async {
    if (_received.isNotEmpty) return _received.removeFirst();
    if (_waiting != null) throw StateError('Concurrent MAG reads');
    final pending = Completer<Uint8List>();
    _waiting = pending;
    try {
      return await pending.future.timeout(const Duration(seconds: 5));
    } finally {
      if (identical(_waiting, pending)) _waiting = null;
    }
  }

  Future<void> _send(Uint8List payload) async {
    final sock = _socket;
    if (sock == null) throw const SocketException('MAG not connected');
    sock.add(payload);
    await sock.flush();
  }

  /// Initiates a new pairing session and prompts the MAG to display a code.
  Future<void> requestPairing() async {
    await open();
    await _send(Mag254Protocol.requestPair(deviceId));
  }

  /// Completes pairing on the same socket; decrypts the reply to prove the code.
  Future<void> confirmPairing(String code) async {
    await _send(Mag254Protocol.completePair(deviceId, code));
    final response = await _next();
    Mag254Protocol.decodeReply(response, code);
  }

  /// Verify the box accepts our saved pairing code before showing controls.
  Future<void> connectPaired() async {
    final code = pairingCode;
    if (code == null || !RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const FormatException('MAG requires TV pairing first.');
    }
    await open();
    await _send(Mag254Protocol.requestConnect(deviceId));
    Mag254Protocol.decodeReply(await _next(), code);
    await _send(Mag254Protocol.ping(deviceId, code));
    Mag254Protocol.decodeReply(await _next(), code);
  }

  Future<void> sendKey(int key) {
    final previous = _sequence;
    final done = Completer<void>();
    _sequence = done.future;
    return () async {
      try {
        await previous;
        final code = pairingCode;
        if (code == null) throw const FormatException('MAG not paired');
        await _send(Mag254Protocol.remoteKey(deviceId, code, key));
        await _send(Mag254Protocol.ping(deviceId, code));
        Mag254Protocol.decodeReply(await _next(), code);
      } finally {
        done.complete();
      }
    }();
  }

  void close() {
    final pending = _waiting;
    _waiting = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const SocketException('MAG disconnected'));
    }
    _events?.cancel();
    _socket?.destroy();
    _socket = null;
  }
}
