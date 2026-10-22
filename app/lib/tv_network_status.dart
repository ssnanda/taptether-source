import 'lg_webos_client.dart';
import 'samsung_tv_client.dart';

/// Reachability is separate from saved authorization. A listening port
/// is not enough to identify a TV.
Future<bool> lgTvResponds(LgTvDevice saved) async {
  final response = await readLgWebOsHello(saved.host,
      connectTimeout: const Duration(milliseconds: 330),
      replyTimeout: const Duration(milliseconds: 850));
  if (response == null) return false;
  if (saved.deviceUuid.isNotEmpty && response.deviceUuid.isNotEmpty) {
    return saved.deviceUuid == response.deviceUuid;
  }
  return true;
}

Future<bool> samsungTvResponds(SamsungTvDevice saved) async {
  final candidate = await probeSamsungTv(saved.host,
      timeout: const Duration(milliseconds: 850));
  if (candidate == null) return false;
  if (saved.deviceId.isNotEmpty && candidate.deviceId.isNotEmpty) {
    return saved.deviceId == candidate.deviceId;
  }
  if (saved.macAddress.isNotEmpty && candidate.macAddress.isNotEmpty) {
    return saved.macAddress == candidate.macAddress;
  }
  return true;
}

/// Only auto-migrate trusted devices after stable-ID matching AND a
/// successful saved-credential reconnection. IP-only matches are forbidden.
Future<LgTvDevice?> relocateLgTv(LgTvDevice saved) async {
  if (saved.clientKey.isEmpty || saved.tlsPin.isEmpty) {
    return null;
  }
  final found = await discoverLgTvs();
  for (final candidate in found) {
    var identified = candidate;
    if (identified.deviceUuid.isEmpty) {
      identified = await readLgWebOsHello(candidate.host) ?? candidate;
    }
    if (candidate.host == saved.host) {
      continue;
    }
    final matchesUuid = saved.deviceUuid.isNotEmpty &&
        identified.deviceUuid == saved.deviceUuid;
    // Existing TLS certificate is a stronger identifier than an IP, and
    // permits recovery for legacy TV pairings without an exposed UUID.
    if (!matchesUuid &&
        !await matchesLgTlsPin(candidate.host, saved.tlsPin)) {
      continue;
    }
    final client = LgWebOsClient(saved.copyWith(host: candidate.host));
    try {
      final verified = await client.connect();
      await LgTvStore().save(verified.copyWith(
          name: saved.name, location: saved.location));
      return verified.copyWith(name: saved.name, location: saved.location);
    } catch (_) {
      // A host must authenticate with the saved key and TLS fingerprint.
    } finally {
      await client.disconnect();
    }
  }
  return null;
}

Future<SamsungTvDevice?> relocateSamsungTv(
    SamsungTvDevice saved) async {
  if (saved.token.isEmpty ||
      (saved.deviceId.isEmpty && saved.macAddress.isEmpty)) {
    return null;
  }
  final found = await discoverSamsungTvs();
  for (final candidate in found) {
    if (candidate.host == saved.host) {
      continue;
    }
    final sameId = saved.deviceId.isNotEmpty &&
        saved.deviceId == candidate.deviceId;
    final sameMac = saved.macAddress.isNotEmpty &&
        saved.macAddress == candidate.macAddress;
    if (!sameId && !sameMac) {
      continue;
    }
    final client = SamsungTvClient(saved.copyWith(host: candidate.host));
    try {
      final verified = await client.connect();
      await SamsungTvStore().save(verified.copyWith(
          name: saved.name, location: saved.location));
      return verified.copyWith(name: saved.name, location: saved.location);
    } catch (_) {
      // Do not migrate a TV on unverified REST identity alone.
    } finally {
      await client.disconnect();
    }
  }
  return null;
}
