import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lan_scan.dart';
import 'tcl_google_tv_protocol/remote_client.dart';
import 'tcl_google_tv_store.dart';

/// Verify *the original paired Google TV*, not merely TCP 6466 availability.
/// The TLS peer must match the saved fingerprint and successfully complete the
/// Remote Service v2 authenticated handshake with the existing phone identity.
Future<bool> tclGoogleTvPairingVerified(TclGoogleTv tv) async {
  if (!tv.paired || !validTclGoogleTvHost(tv.host)) return false;
  RemoteClient? client;
  try {
    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(utf8.encode(tv.certificatePem));
    context.usePrivateKeyBytes(utf8.encode(tv.privateKeyPem));
    client = RemoteClient(
      host: tv.host,
      context: context,
      expectedFingerprint: tv.serverFingerprint,
    );
    await client.connect();
    return client.state == RemoteConnectionState.connected;
  } catch (_) {
    return false;
  } finally {
    client?.dispose();
  }
}

/// Scan the current Wi-Fi subnet only when a paired TV has gone missing.
/// Candidate discovery uses TCP as a hint; a complete authenticated TLS
/// handshake and pinned fingerprint are mandatory before saving a new IP.
/// Discovery is bounded and never stores identities from an unpaired device.
Future<TclGoogleTv?> relocateTclGoogleTv(
  TclGoogleTv tv, {
  DetectedLanRange? network,
  TclGoogleTvStore? store,
  Future<bool> Function(String host)? portReachable,
  Future<bool> Function(TclGoogleTv candidate)? verifyPairing,
}) async {
  if (!tv.paired) return null;
  final lan = network ?? await detectLanRange();
  if (lan == null) return null;
  final probe = portReachable ?? tclGoogleTvPortResponds;
  final verify = verifyPairing ?? tclGoogleTvPairingVerified;
  final targets = <String>[];
  for (final prefix in lan.scanPrefixes.take(4)) {
    for (var last = 1; last < 255; last++) {
      final host = '$prefix.$last';
      if (host != tv.host && validTclGoogleTvHost(host) &&
          lanRangeContains(lan, host)) {
        targets.add(host);
      }
    }
  }
  if (targets.isEmpty) return null;
  final reachable = <String>[];
  var cursor = 0;
  Future<void> worker() async {
    while (cursor < targets.length) {
      final host = targets[cursor++];
      try {
        if (await probe(host)) reachable.add(host);
      } catch (_) {
        // A rejected TCP probe is never treated as a matching device.
      }
    }
  }
  await Future.wait(List.generate(24, (_) => worker()));
  reachable.sort();
  final secure = store ?? TclGoogleTvStore();
  for (final host in reachable) {
    final candidate = tv.copyWith(host: host);
    if (!await verify(candidate)) continue;
    // Matching fingerprint AND successful paired handshake verified.
    return secure.relocate(tv, host);
  }
  return null;
}
