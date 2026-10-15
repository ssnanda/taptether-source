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
  return saved.where((device) {
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
}
