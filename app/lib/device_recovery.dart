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
