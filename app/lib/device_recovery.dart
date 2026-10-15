import 'dart:async';
import 'dart:io';

import 'computer_store.dart';
import 'discovery.dart';
import 'lan_scan.dart';

/// Discovery replies are untrusted address hints. These are never used as
/// proof of identity: the caller must verify the saved certificate pin AND
/// perform authenticated agent ping before changing a stored address.
List<String> recoveryCandidates(
  SavedComputer saved,
  DetectedLanRange network,
  List<DiscoveredDevice> announced, {
  int maxCandidates = 24,
}) {
  if (maxCandidates < 1) return const [];
  final candidates = <String>{};
  if (lanRangeContains(network, saved.host)) {
    candidates.add(saved.host);
  }

  // Prefer a familiar hostname and the /24 of the phone, but don't rely
  // on name alone: some owners rename their Macs, and names are untrusted.
  final ordered = announced.where((entry) =>
      lanRangeContains(network, entry.host)).toList();
  String normalized(String name) =>
      name.toLowerCase().replaceFirst(RegExp(r'\.local\.?$'), '').trim();
  ordered.sort((left, right) {
    int priority(DiscoveredDevice entry) {
      if (normalized(entry.name) == normalized(saved.name)) return 0;
      if (prefixFromIp(entry.host) == network.activePrefix) return 1;
      return 2;
    }
    return priority(left).compareTo(priority(right));
  });
  for (final entry in ordered) {
    candidates.add(entry.host);
    if (candidates.length >= maxCandidates) break;
  }
  return candidates.take(maxCandidates).toList();
}

/// The saved certificate fingerprint, not DHCP IP or hostname, identifies
/// a paired agent across home/office networks. Never match only by address.
bool samePairedAgent(SavedComputer left, SavedComputer right) {
  final leftPin = left.fingerprint.replaceAll(
      RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
  final rightPin = right.fingerprint.replaceAll(
      RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
  return leftPin.length == 64 && leftPin == rightPin;
}

SavedComputer movedDevice(SavedComputer saved, String verifiedIp,
    {String? currentLocation}) {
  if (!isPrivateIPv4(verifiedIp)) {
    throw const FormatException('Only private LAN addresses may be stored');
  }
  return SavedComputer(
    id: saved.id,
    name: saved.name,
    host: verifiedIp,
    token: saved.token,
    fingerprint: saved.fingerprint,
    platform: saved.platform,
    deviceId: saved.deviceId,
    location: currentLocation ?? saved.location,
    customName: saved.customName,
    macAddress: saved.macAddress,
  );
}


/// Enumerate at most a /22 worth of addresses from the current phone Wi-Fi.
/// A /23 has usable addresses on both the .20.x and .21.x halves; do not
/// confuse the CIDR network address with an exact device IP.
List<String> agentTcpProbeAddresses(DetectedLanRange network, {
  int maxAddresses = 1024,
}) {
  if (maxAddresses <= 0) return const [];
  final prefixes = network.scanPrefixes.take(4);
  final networkAddress = network.cidr.split('/').first;
  final numbers = network.ip.split('.').map(int.parse).toList();
  final mask = network.subnetMask.split('.').map(int.parse).toList();
  final broadcastParts = <int>[
    for (var index = 0; index < 4; index++)
      numbers[index] | (255 ^ mask[index]),
  ];
  final broadcast = broadcastParts.join('.');
  final result = <String>[];
  for (final prefix in prefixes) {
    for (var last = 0; last <= 255; last++) {
      final ip = '$prefix.$last';
      if (ip == networkAddress || ip == broadcast ||
          !lanRangeContains(network, ip)) {
        continue;
      }
      result.add(ip);
      if (result.length >= maxAddresses) return result;
    }
  }
  return result;
}

/// Best-effort reachability discovery for TapTether's single TCP agent port.
/// Crucially, an open TCP port is NEVER enough to change a paired device.
/// The caller must authenticate using the SAVED phone identity and TLS pin.
/// This fallback works where UDP discovery/mDNS is blocked on iOS Wi-Fi.
Future<List<String>> probeAgentControlPorts(
  DetectedLanRange network, {
  int parallelism = 48,
  int maxHits = 24,
  Duration timeout = const Duration(milliseconds: 320),
  void Function(String ip, bool accepts)? onProbe,
}) async {
  final addresses = agentTcpProbeAddresses(network);
  final found = <String>[];
  final workers = parallelism.clamp(1, 64);
  for (var index = 0; index < addresses.length; index += workers) {
    final batch = addresses.skip(index).take(workers).toList();
    final hits = await Future.wait(batch.map((ip) async {
      try {
        final socket = await Socket.connect(ip, 48321, timeout: timeout);
        socket.destroy();
        return ip;
      } on SocketException {
        return null;
      } on TimeoutException {
        return null;
      }
    }));
    for (var i = 0; i < batch.length; i++) {
      onProbe?.call(batch[i], hits[i] != null);
    }
    found.addAll(hits.whereType<String>());
    if (found.length >= maxHits) break;
  }
  return found.take(maxHits).toList();
}
