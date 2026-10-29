import 'lg_thinq_api.dart';
import 'lg_webos_client.dart';

/// A MAC returned by LG's cloud inventory. Cloud device IDs do not prove
/// LAN pairing identity; only a matching immutable identifier can do that.
class ThinQTvMacHint {
  const ThinQTvMacHint({
    required this.mac,
    required this.alias,
    required this.model,
    required this.identifiers,
  });

  final String mac;
  final String alias;
  final String model;
  final Set<String> identifiers;
}

/// Ignore non-TV devices, incomplete MACs and unrelated cloud records.
/// Only documented, narrowly scoped fields are extracted from LG payloads.
List<ThinQTvMacHint> parseThinQTvMacHints(Object? raw) {
  final entries = raw is List ? raw :
      raw is Map ? (raw['devices'] ?? raw['items']) : null;
  if (entries is! List) { return const []; }
  String str(Object? value) => value is String ? value.trim() : '';
  final results = <ThinQTvMacHint>[];

  for (final entry in entries.take(80)) {
    if (entry is! Map) { continue; }
    final device = LgThinQDevice.parse(entry);
    if (device == null || !device.isTelevision) { continue; }
    final info = entry['deviceInfo'] is Map
        ? entry['deviceInfo'] as Map : entry;
    final network = entry['networkInfo'] is Map
        ? entry['networkInfo'] as Map : <String, Object?>{};
    final details = info['network'] is Map
        ? info['network'] as Map : <String, Object?>{};
    final identifiers = <String>{};
    for (final node in [entry, info]) {
      for (final key in [
        'deviceUUID', 'deviceUuid', 'uuid', 'serialNumber', 'serialNo',
      ]) {
        final value = str(node[key]);
        if (value.length >= 8) { identifiers.add(value.toUpperCase()); }
      }
    }
    // LG ThinQ deviceId is a cloud account identifier; it must NOT be
    // treated as a webOS TV UUID.
    final fields = <String>[
      for (final node in [network, details, info, entry])
        for (final key in [
          'activeMacAddress', 'wifiMacAddress', 'wiFiMacAddress',
          'ethernetMacAddress', 'wiredMacAddress', 'macAddress',
        ])
          str(node[key]),
    ];
    final macs = fields.map(canonicalLgMac).whereType<String>().toSet();
    // Conflicting Wi-Fi/Ethernet MACs with no reported active interface
    // need review. They cannot be selected automatically.
    if (macs.length != 1) { continue; }
    results.add(ThinQTvMacHint(
      mac: macs.single,
      alias: device.name,
      model: device.model,
      identifiers: identifiers,
    ));
  }
  return results;
}

bool thinQHintVerifiedForTv(ThinQTvMacHint hint, LgTvDevice tv) {
  final known = <String>{
    if (tv.deviceUuid.trim().length >= 8)
      tv.deviceUuid.trim().toUpperCase(),
    if ((tv.about['Serial number'] ?? '').trim().length >= 8)
      tv.about['Serial number']!.trim().toUpperCase(),
  };
  return known.isNotEmpty &&
      hint.identifiers.intersection(known).isNotEmpty;
}

/// Prefer verified identity matches. Names are only a reviewable suggestion:
/// a user can rename either TV, and two rooms may have identical models.
ThinQTvMacHint? matchingThinQMacHint(
    LgTvDevice tv, List<ThinQTvMacHint> hints,
    {bool requireVerification = true}) {
  final verified = hints.where((hint) =>
      thinQHintVerifiedForTv(hint, tv)).toList();
  if (verified.length == 1) { return verified.single; }
  if (requireVerification || verified.length > 1) { return null; }
  final name = tv.name.trim().toLowerCase();
  final byName = hints.where((hint) =>
      hint.alias.trim().toLowerCase() == name).toList();
  return byName.length == 1 ? byName.single : null;
}

Future<ThinQTvMacHint?> findThinQTvMac(LgTvDevice tv,
    {bool requireVerification = true}) async {
  final store = LgThinQStorage();
  final token = await store.token();
  if (token == null || token.isEmpty) return null;
  final api = LgThinQClient(
    personalToken: token,
    country: await store.country(),
    clientId: await store.clientId(),
  );
  final raw = await api.tvNetworkInventory();
  final hints = parseThinQTvMacHints(raw);
  return matchingThinQMacHint(tv, hints,
      requireVerification: requireVerification);
}
