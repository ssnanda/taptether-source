import 'computer_store.dart';
import 'lan_scan.dart';

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
    return matchesLocation && (showOffline || online[device.id] == true);
  }).toList();
  // Fast dashboard: keep saved order within each group, but surface online
  // machines first, followed by pending verification, then offline machines.
  // A saved machine never disappears just because its Wi-Fi is unavailable.
  int priority(String id) => online[id] == true ? 0
      : online[id] == null ? 1 : 2;
  filtered.sort((a, b) => priority(a.id).compareTo(priority(b.id)));
  return filtered;
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
