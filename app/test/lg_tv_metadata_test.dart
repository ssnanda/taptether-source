import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_tv_metadata.dart';

void main() {
  test('keyed LG system response extracts reported model and TV capabilities',
      () {
    final info = lgTvMetadataFromPayload('system', {
      'returnValue': true,
      'modelName': 'OLED65C4PUA',
      'firmwareVersion': '23.20.10',
      'sdkVersion': '9.0.0',
      'UHD': 'true',
      '_3d': 'false',
      'serialNumber': 'private-serial-do-not-store',
    });
    expect(info['Model'], 'OLED65C4PUA');
    expect(info['Firmware'], '23.20.10');
    expect(info['webOS SDK'], '9.0.0');
    expect(info['4K UHD'], 'Supported');
    expect(info['3D playback'], 'Not supported');
    expect(info.containsKey('Serial number'), isFalse);
    expect(info.values, isNot(contains('private-serial-do-not-store')));
  });

  test('software and HDMI details are only shown when returned', () {
    expect(lgTvMetadataFromPayload('software', {
      'sw_version': '04.40.76',
      'webos_version': 'webOS 24',
    }), {
      'Firmware': '04.40.76',
      'webOS version': 'webOS 24',
    });
    expect(lgTvMetadataFromPayload('inputs', {
      'devices': [
        {'id': 'HDMI_1', 'label': 'Apple TV', 'connected': true},
        {'id': 'HDMI_2', 'label': 'HDMI 2', 'connected': false},
        {'id': 'AV_1', 'label': 'AV 1', 'connected': false},
      ]
    }), {
      'HDMI inputs': '2',
      'Connected HDMI': 'Apple TV',
    });
    expect(lgTvMetadataFromPayload('system', {}),
        isEmpty);
  });
}
