import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart';

import 'discovery.dart';
import 'lan_scan.dart';
import 'xbox_smartglass.dart';

/// A direct, local Xbox One-family SmartGlass session. No browser, Microsoft
/// sign-in, web API, intermediary agent, or arbitrary plaintext button packets.
/// The console must expose the legacy encrypted LAN protocol on UDP 5050.
/// Series X|S firmware may reject this protocol; a timeout is not a connection.
class XboxLanException implements Exception {
  const XboxLanException(this.message);
  final String message;
  @override
  String toString() => message;
}

class XboxLanMessage {
  const XboxLanMessage(this.type, this.sequence, this.payload,
      this.flags, this.channel);
  final int type;
  final int sequence;
  final Uint8List payload;
  final int flags;
  final int channel;
}

int _word(List<int> bytes, int offset) =>
    ByteData.sublistView(Uint8List.fromList(bytes)).getUint16(offset);

int _dword(List<int> bytes, int offset) =>
    ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(offset);

int _qword(List<int> bytes, int offset) =>
    ByteData.sublistView(Uint8List.fromList(bytes)).getUint64(offset);

Uint8List _u16(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value);
Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);
Uint8List _u64(int value) =>
    Uint8List(8)..buffer.asByteData().setUint64(0, value);

List<int> _sg(String text) {
  final bytes = utf8.encode(text);
  return [..._u16(bytes.length), ...bytes, 0];
}

Uint8List _randomBytes(int count) {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(count, (_) => rng.nextInt(256)));
}

/// Retrieves the DER certificate from an already structurally validated DD01
/// frame. Do not persist the raw certificate with device backups.
Uint8List? xboxLanCertificate(List<int> packet, String host) {
  if (!inspectXboxDiscovery(packet, host).compatible) return null;
  final view = ByteData.sublistView(Uint8List.fromList(packet));
  var offset = 14;
  for (var field = 0; field < 2; field++) {
    final size = view.getUint16(offset);
    offset += 2 + size + 1;
  }
  offset += 4;
  final size = view.getUint16(offset);
  offset += 2;
  return Uint8List.fromList(packet.sublist(offset, offset + size));
}

/// Locate P-256 subjectPublicKeyInfo inside an X.509 DER certificate.
/// Reject certificates without the named EC public-key/curve identifiers.
/// The previously saved certificate SHA-256 pin is checked separately.
Uint8List xboxLanP256Point(List<int> certificate) {
  const algorithm = [0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01];
  const curve = [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];
  for (var i = 0; i + algorithm.length < certificate.length; i++) {
    if (!_at(certificate, i, algorithm)) continue;
    for (var j = i + algorithm.length;
        j < i + algorithm.length + 20 && j + 70 < certificate.length; j++) {
      if (!_at(certificate, j, curve)) continue;
      for (var k = j + curve.length;
          k < j + curve.length + 8 && k + 69 <= certificate.length; k++) {
        // SubjectPublicKeyInfo BIT STRING: 66 bytes, no unused bits, EC04.
        if (_at(certificate, k, const [0x03, 0x42, 0x00, 0x04])) {
          return Uint8List.fromList(certificate.sublist(k + 3, k + 68));
        }
      }
    }
  }
  throw const XboxLanException(
      'Xbox certificate does not contain a supported P-256 key.');
}

bool _at(List<int> source, int offset, List<int> pattern) {
  if (offset < 0 || offset + pattern.length > source.length) return false;
  for (var n = 0; n < pattern.length; n++) {
    if (source[offset + n] != pattern[n]) return false;
  }
  return true;
}

/// Legacy SmartGlass uses nonstandard PKCS7: no extra block when aligned.
Uint8List _pad(List<int> plaintext) {
  final pad = (16 - plaintext.length % 16) % 16;
  return Uint8List.fromList([...plaintext, ...List.filled(pad, pad)]);
}

Uint8List _cbc(List<int> key, List<int> iv, List<int> data,
    {required bool encrypt}) {
  if (data.length % 16 != 0) {
    throw const XboxLanException('Invalid encrypted Xbox packet size.');
  }
  final cipher = CBCBlockCipher(AESEngine())
    ..init(encrypt, ParametersWithIV<KeyParameter>(
        KeyParameter(Uint8List.fromList(key)), Uint8List.fromList(iv)));
  final result = Uint8List(data.length);
  for (var n = 0; n < data.length; n += 16) {
    cipher.processBlock(Uint8List.fromList(data), n, result, n);
  }
  return result;
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

class XboxLanSession {
  XboxLanSession._(this.host, this._known, this._onProgress);
  final String host;
  final XboxConsole? _known;
  final void Function(String)? _onProgress;
  String? _lastDiscoveryRejection;
  int _discoveryReplies = 0;
  XboxConsole? discovered;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _heartbeat;
  final List<Uint8List> _inbox = [];
  Completer<Uint8List>? _pending;
  bool Function(Uint8List)? _pendingMatch;
  List<int>? _encryptionKey;
  List<int>? _ivKey;
  List<int>? _hmacKey;
  int _participant = 0;
  int _sequence = 1;
  int _receivedSequence = 0;
  int _inputChannel = 0;
  bool _connected = false;
  bool _closed = false;

  bool get connected => _connected && !_closed;

  static Future<XboxLanSession> connect(String host,
      {XboxConsole? known, void Function(String)? onProgress}) async {
    if (!isPrivateIPv4(host)) {
      throw const XboxLanException('Enter a private Xbox Wi-Fi address.');
    }
    final range = await detectLanRange();
    if (range == null || !lanRangeContains(range, host)) {
      throw const XboxLanException(
          'Connect the iPhone to the same Wi-Fi network as the Xbox.');
    }
    final session = XboxLanSession._(host, known, onProgress);
    try {
      await session._open();
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<void> _open() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket = socket;
    _onProgress?.call('Checking $host · local UDP 5050');
    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read || _closed) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final packet = datagram!;
        if (packet.address.address != host || packet.port != 5050) continue;
        final bytes = Uint8List.fromList(packet.data);
        if (bytes.length >= 2 && _word(bytes, 0) == 0xdd01) {
          _discoveryReplies++;
          final diagnosis = inspectXboxDiscovery(bytes, host);
          if (!diagnosis.compatible) {
            _lastDiscoveryRejection = diagnosis.reason;
          }
        }
        final pending = _pending;
        if (pending != null && !pending.isCompleted &&
            (_pendingMatch?.call(bytes) ?? false)) {
          pending.complete(bytes);
        } else if (_inbox.length < 64) {
          _inbox.add(bytes);
        }
      }
    });
    Uint8List? discovery;
    for (var n = 0; n < 3 && discovery == null; n++) {
      _send(Uint8List.fromList(xboxDiscoveryPacket()));
      try {
        discovery = await _await((p) => p.length >= 2 &&
            _word(p, 0) == 0xdd01 &&
            inspectXboxDiscovery(p, host).compatible,
            const Duration(milliseconds: 1250));
      } on TimeoutException {
        // Console firmware may ignore this older LAN protocol.
      }
    }
    if (discovery == null) {
      if (_discoveryReplies > 0) {
        throw XboxLanException(
          'Xbox replied to UDP 5050, but its discovery packet was rejected: '
          '${_lastDiscoveryRejection ?? "invalid legacy response"}.');
      }
      throw XboxLanException(
        '$host did not respond to legacy Xbox discovery on UDP 5050. '
        'The correct IP alone cannot enable this protocol.');
    }
    final identity = inspectXboxDiscovery(discovery, host).console!;
    if (_known != null &&
        (_known.uuid != identity.uuid ||
         _known.certificateSha256 != identity.certificateSha256)) {
      throw const XboxLanException(
          'Xbox identity changed. Verify the device before connecting.');
    }
    discovered = identity;
    _onProgress?.call('Xbox identified · starting encrypted LAN connection');
    final certificate = xboxLanCertificate(discovery, host)!;
    final point = xboxLanP256Point(certificate);
    final ecdh = Ecdh.p256(length: 32);
    final pair = await ecdh.newKeyPair();
    final public = await pair.extractPublicKey();
    final remote = EcPublicKey(
        x: point.sublist(1, 33), y: point.sublist(33, 65),
        type: KeyPairType.p256);
    final secret = await ecdh.sharedSecretKey(
        keyPair: pair, remotePublicKey: remote);
    final raw = await secret.extractBytes();
    final combined = <int>[
      0xd6, 0x37, 0xf1, 0xaa, 0xe2, 0xf0, 0x41, 0x8c,
      ...raw,
      0xa8, 0xf8, 0x1a, 0x57, 0x4e, 0x22, 0x8a, 0xb7
    ];
    final material = hashes.sha512.convert(combined).bytes;
    _encryptionKey = material.sublist(0, 16);
    _ivKey = material.sublist(16, 32);
    _hmacKey = material.sublist(32, 64);
    final iv = _randomBytes(16);
    final pub = <int>[4, ...public.x, ...public.y];
    final clear = <int>[
      ..._randomBytes(16), ..._u16(0), ...pub, ...iv
    ];
    final protected = <int>[..._sg(''), ..._sg(''),
        ..._u32(0), ..._u32(0), ..._u32(1)];
    final header = <int>[..._u16(0xcc00), ..._u16(clear.length),
        ..._u16(protected.length), ..._u16(2)];
    final ciphertext = _cbc(_encryptionKey!, iv, _pad(protected),
        encrypt: true);
    final signed = <int>[...header, ...clear, ...ciphertext];
    final hmac = hashes.Hmac(hashes.sha256, _hmacKey!).convert(signed).bytes;
    _send(Uint8List.fromList([...signed, ...hmac]));
    _onProgress?.call('Xbox discovered · checking encrypted handshake');
    late final Uint8List response;
    try {
      response = await _await((p) => p.length >= 2 &&
          _word(p, 0) == 0xcc01, const Duration(seconds: 4));
    } on TimeoutException {
      throw const XboxLanException(
          'Xbox did not accept the encrypted local connection.');
    }
    if (response.length < 8 + 16 + 16 + 32) {
      throw const XboxLanException('Incomplete Xbox connection response.');
    }
    final plainLength = _word(response, 4);
    final unprotectedLength = _word(response, 2);
    final encryptedLength = ((plainLength + 15) ~/ 16) * 16;
    final signedLength = 8 + unprotectedLength + encryptedLength;
    if (unprotectedLength != 16 || plainLength < 8 ||
        response.length != signedLength + 32 ||
        !_equal(response.sublist(signedLength),
            hashes.Hmac(hashes.sha256, _hmacKey!)
                .convert(response.sublist(0, signedLength)).bytes)) {
      throw const XboxLanException('Xbox rejected the secure handshake.');
    }
    final answer = _cbc(_encryptionKey!, response.sublist(8, 24),
        response.sublist(24, signedLength), encrypt: false);
    final result = _word(answer, 0);
    if (result != 0) {
      throw XboxLanException(
          'Xbox denied the local controller connection (status $result).');
    }
    _participant = _dword(answer, 4);
    _onProgress?.call('Encrypted session · confirming Xbox pairing');
    _sendMessage(0x03, <int>[
      ..._u16(6), ..._u16(1170), ..._u16(2532),
      ..._u16(160), ..._u16(160), ..._u64(0),
      ..._u32(15), ..._u32(17), ..._u32(0),
      ..._sg('TapTether')
    ], needAck: true);
    try {
      await _awaitMessage(0x01, const Duration(seconds: 3));
    } on TimeoutException {
      throw const XboxLanException('Xbox did not confirm local pairing.');
    }
    const inputGuid = <int>[
      0xfa, 0x20, 0xb8, 0xca, 0x66, 0xfb, 0x46, 0xe0,
      0xad, 0xb6, 0x0b, 0x97, 0x8a, 0x59, 0xd3, 0x5f
    ];
    _sendMessage(0x26, <int>[
      ..._u32(0), ..._u32(0), ...inputGuid, ..._u32(0)
    ]);
    XboxLanMessage channel;
    try {
      channel = await _awaitMessage(0x27, const Duration(seconds: 4));
    } on TimeoutException {
      throw const XboxLanException(
          'Xbox did not open its local controller input channel.');
    }
    if (channel.payload.length < 16 ||
        _dword(channel.payload, 0) != 0 ||
        _dword(channel.payload, 12) != 0) {
      throw const XboxLanException('Xbox refused controller input.');
    }
    _inputChannel = _qword(channel.payload, 4);
    _onProgress?.call('Xbox input channel opened');
    _connected = true;
    _heartbeat = Timer.periodic(const Duration(seconds: 4), (_) {
      if (connected) {
        _sendMessage(0x01, <int>[
          ..._u32(_receivedSequence), ..._u32(0), ..._u32(0)
        ]);
      }
    });
  }

  void _send(Uint8List data) {
    if (_closed || _socket?.send(data, InternetAddress(host), 5050) !=
        data.length) {
      throw const XboxLanException('Unable to transmit Xbox LAN packet.');
    }
  }

  Future<Uint8List> _await(bool Function(Uint8List) matcher,
      Duration limit) async {
    for (var i = 0; i < _inbox.length; i++) {
      if (matcher(_inbox[i])) return _inbox.removeAt(i);
    }
    final pending = Completer<Uint8List>();
    _pending = pending;
    _pendingMatch = matcher;
    try {
      return await pending.future.timeout(limit);
    } finally {
      if (identical(_pending, pending)) {
        _pending = null;
        _pendingMatch = null;
      }
    }
  }

  XboxLanMessage? _decode(Uint8List bytes) {
    if (bytes.length < 26 + 32 || _encryptionKey == null ||
        _word(bytes, 0) != 0xd00d) {
      return null;
    }
    final clearLength = _word(bytes, 2);
    final cipherLength = ((clearLength + 15) ~/ 16) * 16;
    final signedLength = 26 + cipherLength;
    if (clearLength > 4096 || bytes.length != signedLength + 32 ||
        !_equal(bytes.sublist(signedLength),
          hashes.Hmac(hashes.sha256, _hmacKey!)
              .convert(bytes.sublist(0, signedLength)).bytes)) {
      return null;
    }
    final iv = _cbc(_ivKey!, List<int>.filled(16, 0),
        bytes.sublist(0, 16), encrypt: true);
    final payload = _cbc(_encryptionKey!, iv,
        bytes.sublist(26, signedLength), encrypt: false);
    final sequence = _dword(bytes, 4);
    if (sequence > _receivedSequence) _receivedSequence = sequence;
    return XboxLanMessage(_word(bytes, 16) & 0x0fff, sequence,
        Uint8List.fromList(payload.sublist(0, clearLength)),
        _word(bytes, 16), _qword(bytes, 18));
  }

  Future<XboxLanMessage> _awaitMessage(int type, Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      final left = deadline.difference(DateTime.now());
      final bytes = await _await((p) =>
          p.length >= 2 && _word(p, 0) == 0xd00d, left);
      final message = _decode(bytes);
      if (message == null) continue;
      if (message.flags & 0x2000 != 0) {
        _sendMessage(0x01, <int>[
          ..._u32(message.sequence), ..._u32(0), ..._u32(0)
        ]);
      }
      if (message.type == type) return message;
      if (message.type == 0x2a) {
        throw const XboxLanException('Xbox ended the local connection.');
      }
    }
    throw TimeoutException('No Xbox message');
  }

  void _sendMessage(int type, List<int> payload,
      {int channel = 0, bool needAck = false}) {
    final header = <int>[
      ..._u16(0xd00d), ..._u16(payload.length),
      ..._u32(_sequence++), ..._u32(0), ..._u32(_participant),
      ..._u16(0x8000 | (needAck ? 0x2000 : 0) | type),
      ..._u64(channel)
    ];
    final iv = _cbc(_ivKey!, List<int>.filled(16, 0),
        header.sublist(0, 16), encrypt: true);
    final cipher = _cbc(_encryptionKey!, iv, _pad(payload),
        encrypt: true);
    final signed = <int>[...header, ...cipher];
    final hmac = hashes.Hmac(hashes.sha256, _hmacKey!).convert(signed).bytes;
    _send(Uint8List.fromList([...signed, ...hmac]));
  }

  /// Held buttons are sent with an explicit release, not a fabricated
  /// browser Gamepad API. Valid only after input channel acknowledgement.
  void buttons(int mask) {
    if (!connected) {
      throw const XboxLanException('Xbox LAN remote is not connected.');
    }
    if (mask < 0 || mask > 0xffff) {
      throw const XboxLanException('Invalid Xbox controller button mask.');
    }
    final data = <int>[
      ..._u64(DateTime.now().microsecondsSinceEpoch),
      ..._u16(mask), ...List<int>.filled(24, 0)
    ];
    _sendMessage(0xf0a, data, channel: _inputChannel);
  }

  Future<void> close() async {
    if (_closed) return;
    if (_connected) {
      try {
        buttons(0);
        _sendMessage(0x2a, [..._u32(4), ..._u32(0)]);
      } catch (_) {}
    }
    _closed = true;
    _connected = false;
    _heartbeat?.cancel();
    await _subscription?.cancel();
    _socket?.close();
    _inbox.clear();
  }
}

/// Button values are the documented SmartGlass controller bitfield.
abstract final class XboxLanButton {
  static const xbox = 0x0002;
  static const menu = 0x0004;
  static const view = 0x0008;
  static const a = 0x0010;
  static const b = 0x0020;
  static const x = 0x0040;
  static const y = 0x0080;
  static const up = 0x0100;
  static const down = 0x0200;
  static const left = 0x0400;
  static const right = 0x0800;
  static const lb = 0x1000;
  static const rb = 0x2000;
}
