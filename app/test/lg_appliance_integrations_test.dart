import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/lg_appliance_discovery.dart';
import 'package:taptether/lg_thinq_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('SSDP discovery only considers LG hints on the current subnet', () {
    final network = rangeFromWifi(
        '192.168.68.100', '255.255.255.0')!;
    const response = 'HTTP/1.1 200 OK\r\n'
        'SERVER: Linux/3.4 UPnP/1.0 LGE Appliance\r\n'
        'ST: urn:lge-com:service:washer:1\r\n'
        'MODELNAME: WM1234HBA\r\n'
        'FRIENDLYNAME: Laundry Washer\r\n\r\n';
    final found = applianceFromSsdp('192.168.68.90', response, network);
    expect(found, isNotNull);
    expect(found!.model, 'WM1234HBA');
    expect(found.ip, '192.168.68.90');
    expect(applianceFromSsdp('192.168.1.90', response, network), isNull);
    expect(applianceFromSsdp('192.168.68.91',
        'HTTP/1.1 200 OK\r\nSERVER: random printer\r\n', network),
        isNull);
    final report = lgLanDiagnostic(network, [found]);
    expect(report, contains('WM1234HBA'));
    expect(report, isNot(contains('Authorization')));
  });

  test('ThinQ inventory filters malformed IDs and recognizes appliances', () {
    final devices = parseThinQDevices([
      {'deviceId':'abc1','deviceInfo':{
          'deviceType':'DEVICE_WASHER',
          'alias':'Laundry Washer','modelName':'WM1234'}},
      {'deviceId':'abc2','deviceInfo':{
          'deviceType':'DEVICE_REFRIGERATOR',
          'alias':'Kitchen','modelName':'LRFXC'}},
      {'deviceType':'DEVICE_DRYER','alias':'Missing ID'},
    ]);
    expect(devices.length, 2);
    expect(devices.first.isAppliance, isTrue);
    expect(devices.last.model, 'LRFXC');
    expect(thinQRegion('US'), 'aic');
    expect(thinQRegion('AU'), 'kic');
    expect(thinQRegion('GB'), 'eic');
  });

  test('cloud token and explicitly enabled devices use secure storage',
      () async {
    final store = LgThinQStorage();
    expect(await store.token(), isNull);
    expect(await store.enabledDevices(), isEmpty);
    await store.configure('personal-access-token-long-value', 'US');
    expect(await store.token(), 'personal-access-token-long-value');
    const washer = LgThinQDevice(
      id:'w1', name:'Laundry Washer', type:'DEVICE_WASHER');
    await store.setEnabled(washer, true);
    expect((await store.enabledDevices()).single.id, 'w1');
    await store.setEnabled(washer, false);
    expect(await store.enabledDevices(), isEmpty);
    await store.setEnabled(washer, true);
    await store.disconnect();
    expect(await store.token(), isNull);
    expect(await store.enabledDevices(), isEmpty);
  });

  test('status report selects safe fields, ignores account and secrets', () {
    final summary = safeThinQSummary({
      'name':'do-not-show-name',
      'token':'SECRET',
      'deviceInfo': {
        'modelName':'WM1234',
        'operation': {'runState':'RUNNING'},
        'serialNumber':'PRIVATE',
      },
    });
    expect(summary['modelName'], 'WM1234');
    expect(summary['runState'], 'RUNNING');
    expect(summary.toString(), isNot(contains('SECRET')));
    expect(summary.toString(), isNot(contains('PRIVATE')));
  });
}
