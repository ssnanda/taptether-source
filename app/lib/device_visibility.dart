import 'computer_store.dart';
import 'lan_scan.dart';

/// Every saved pairing is shown in All Devices, regardless of the current
/// Wi-Fi or last-known IP. This is inventory, NOT reachability or permission
/// to connect. Preserve same-address pairings with different identities.
List<SavedComputer> allSavedComputers(
  List<SavedComputer> saved, {
  required Map<String, bool> online,
  required DetectedLanRange? currentNetwork,
}) {
  final result = saved.toList();
  bool verifiedHere(SavedComputer device) => currentNetwork != null &&
      lanRangeContains(currentNetwork, device.host) &&
      online[device.id] == true;
  result.sort((a, b) {
    final first = verifiedHere(a) ? 0 : 1;
    final second = verifiedHere(b) ? 0 : 1;
    return first.compareTo(second);
  });
  return result;
}

/// An address on another Wi-Fi remains saved but must not appear connected.
bool savedDeviceOnNetwork(DetectedLanRange? network, String host) =>
    network != null && lanRangeContains(network, host);

/// Filters the local dashboard only. A device is "online" exclusively after
/// an authenticated TLS-pinned heartbeat, never based on its IP or port alone.
List<SavedComputer> visibleSavedDevices(
  List<SavedComputer> saved, {
  required Map<String, bool> online,
  required String locationFilter,
  required String? currentLocation,
  required DetectedLanRange? currentNetwork,
  required bool showOffline,
}) {
  final selectedLocation = locationFilter == 'automatic'
      ? currentLocation
      : (locationFilter == 'all' ? null : locationFilter);
  final filtered = saved.where((device) {
    // A verified device can travel between Home and Office. In automatic
    // mode its current, TLS-authenticated on-link status overrides a stale
    // manually labeled location; explicit Home/Office filters stay strict.
    final onCurrentNetwork = currentNetwork != null &&
        lanRangeContains(currentNetwork, device.host);
    final activeHere = locationFilter == 'automatic' &&
        online[device.id] == true && onCurrentNetwork;
    final matchesLocation = activeHere || (selectedLocation != null
        ? device.location == selectedLocation
        : (locationFilter == 'automatic' && currentNetwork != null
            ? onCurrentNetwork : true));
    // My Devices represents only this Wi-Fi, even under "All locations".
    // An IP last verified on another subnet must not remain visible.
    // Discovery may later authenticate this same pairing at a new local IP.
    if (!onCurrentNetwork) return false;
    if (online[device.id] != true) {
      return showOffline &&
          (locationFilter == 'automatic' || matchesLocation);
    }
    return matchesLocation;
  }).toList();
  // Fast dashboard: keep saved order within each group, but surface online
  // machines first, followed by pending verification, then offline machines.
  // Other-network offline devices remain in Manage Devices, not this list.
  int priority(String id) => online[id] == true ? 0
      : online[id] == null ? 1 : 2;
  filtered.sort((a, b) => priority(a.id).compareTo(priority(b.id)));
  // A stale pairing may still point at an IP now occupied by a *verified*
  // online device. Hide that conflicting offline/checking alias on the
  // dashboard, but never delete or merge its saved credentials: an address
  // alone is not a trusted device identity. Manage Devices retains both.
  final verifiedHosts = filtered
      .where((device) => online[device.id] == true)
      .map((device) => device.host)
      .toSet();
  final visibleVerifiedHosts = <String>{};
  return filtered.where((device) {
    if (!verifiedHosts.contains(device.host)) {
      return true;
    }
    return online[device.id] == true &&
        visibleVerifiedHosts.add(device.host);
  }).toList();
}


/// A saved pairing isn't evidence that its computer is reachable.
/// Only a current authenticated TLS-pinned heartbeat permits one-tap remote.
/// 'Checking' (null) and confirmed offline (false) cannot start a connection.
bool canConnectSavedDevice(bool? confirmedOnline, {required bool connecting}) =>
    confirmedOnline == true && !connecting;

/// Actionable dashboard guidance when no paired computer answered its last
/// authenticated check. Do not confuse "none online" with "nothing paired".
String? savedDeviceAvailabilityHint({
  required int savedCount,
  required int onlineCount,
  required bool checking,
}) {
  if (savedCount == 0 || checking || onlineCount > 0) return null;
  return 'No computers are responding. Check that your phone is on the '
      'same network and TapTether Agent is running, then tap Refresh.';
}
