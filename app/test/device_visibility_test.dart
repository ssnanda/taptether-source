import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/computer_store.dart';
import 'package:taptether/device_visibility.dart';
import 'package:taptether/lan_scan.dart';

void main() {
  SavedComputer host(String id, String ip, String location) =>
      SavedComputer(id: id, name: id, host: ip,
        token: 'abcdefghijklmnopqrstuvwxy0123456789',
        fingerprint: List.filled(64, 'A').join(),
        location: location);

  test('default dashboard hides unverified and offline devices', () {
    final devices = [
      host('home-online', '192.168.68.81', 'home'),
      host('home-offline', '192.168.68.87', 'home'),
      host('office-online', '10.30.1.10', 'office'),
    ];
    final home = rangeFromWifi('192.168.68.100', '255.255.252.0')!;
    final online = {'home-online': true, 'home-offline': false,
      'office-online': true};
    final visible = visibleSavedDevices(devices, online: online,
        locationFilter: 'automatic', currentLocation: 'home',
        currentNetwork: home, showOffline: false);
    expect(visible.map((d) => d.id), ['home-online']);
  });

  test('show offline and manual categories always remain available', () {
    final devices = [
      host('home', '192.168.68.81', 'home'),
      host('office', '10.30.1.10', 'office'),
    ];
    final visible = visibleSavedDevices(devices,
      online: {'home': false, 'office': true},
      locationFilter: 'home', currentLocation: 'office',
      currentNetwork: null, showOffline: true);
    expect(visible.map((d) => d.id), ['home']);
  });

  test('verified roaming computer shows in automatic Office even if labeled Home', () {
    final mac = host('mac', '192.168.21.242', 'home');
    final network = rangeFromWifi(
        '192.168.21.252', '255.255.254.0')!;
    final current = visibleSavedDevices([mac],
      online: {'mac': true}, locationFilter: 'automatic',
      currentLocation: 'office', currentNetwork: network,
      showOffline: false);
    expect(current.map((d) => d.id), ['mac']);
    final manual = visibleSavedDevices([mac],
      online: {'mac': true}, locationFilter: 'office',
      currentLocation: 'office', currentNetwork: network,
      showOffline: true);
    expect(manual, isEmpty);
  });

  test('unlabeled Wi-Fi networks filter to actual subnet', () {
    final devices = [
      host('here', '192.168.71.15', 'other'),
      host('elsewhere', '10.0.0.11', 'other'),
    ];
    final network = rangeFromWifi('192.168.68.10', '255.255.252.0')!;
    final visible = visibleSavedDevices(devices,
      online: {'here': true, 'elsewhere': true},
      locationFilter: 'automatic', currentLocation: null,
      currentNetwork: network, showOffline: false);
    expect(visible.map((d) => d.id), ['here']);
  });
  test('all saved devices remain visible and online ones lead the list', () {
    final saved = [
      host('offline', '192.168.68.80', 'home'),
      host('checking', '192.168.68.81', 'home'),
      host('online', '192.168.68.82', 'home'),
      host('office-offline', '10.0.118.22', 'office'),
    ];
    final visible = visibleSavedDevices(saved,
      online: {'online': true, 'offline': false, 'office-offline': false},
      locationFilter: 'all', currentLocation: 'home',
      currentNetwork: rangeFromWifi('192.168.68.25', '255.255.252.0'),
      showOffline: true);
    expect(visible.map((device) => device.id),
      ['online', 'checking', 'offline', 'office-offline']);
    // The default dashboard does not require a subnet scan to show saved
    // entries; online means exclusively authenticated saved-host checks.
    final initial = visibleSavedDevices(saved,
      online: {}, locationFilter: 'all', currentLocation: null,
      currentNetwork: null, showOffline: true);
    expect(initial.map((device) => device.id),
      ['offline', 'checking', 'online', 'office-offline']);
  });

}
