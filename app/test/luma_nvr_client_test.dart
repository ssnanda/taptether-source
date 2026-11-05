import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/luma_nvr_client.dart';

void main() {
  const infoXml = '''
<DeviceInfo version="1.0" xmlns="http://www.isapi.org/ver20/XMLSchema">
<deviceName>Family NVR</deviceName>
<model>Luma 500</model><firmwareVersion>V4.2</firmwareVersion>
<serialNumber>TEST-123</serialNumber>
</DeviceInfo>''';

  const channelXml = '''
<InputProxyChannelList xmlns="http://www.isapi.org/ver20/XMLSchema">
<InputProxyChannel><id>2</id><name>Front Door</name></InputProxyChannel>
<InputProxyChannel><id>1</id><name>Driveway &amp; Yard</name></InputProxyChannel>
<InputProxyChannel><id>65</id><name>Invalid</name></InputProxyChannel>
</InputProxyChannelList>''';

  const statusXml = '''
<InputProxyChannelStatusList>
<InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus>
<InputProxyChannelStatus><id>2</id><online>false</online></InputProxyChannelStatus>
</InputProxyChannelStatusList>''';

  test('host accepts local HTTPS address and optional port', () {
    final defaultPort = LumaNvrSettings.fromInput(
        '192.168.1.79', 'admin', 'test-secret');
    expect(defaultPort.host, '192.168.1.79');
    expect(defaultPort.port, 443);
    expect(defaultPort.address, '192.168.1.79');

    final custom = LumaNvrSettings.fromInput(
        'luma.local:45679', 'admin', 'test-secret');
    expect(custom.host, 'luma.local');
    expect(custom.port, 45679);
    expect(custom.address, 'luma.local:45679');
    expect(LumaNvrSettings.fromJson(custom.toJson()).password, 'test-secret');
  });

  test('host rejects URL syntax, invalid ports and empty credentials', () {
    for (final value in [
      'https://192.168.1.79',
      '192.168.1.79/login',
      'host:0',
      'host:65536',
      'host:abc',
      'host@evil.com',
      'host with spaces',
      '',
    ]) {
      expect(() => LumaNvrSettings.fromInput(value, 'admin', 'pw'),
          throwsA(isA<LumaNvrException>()));
    }
    expect(() => LumaNvrSettings.fromInput(
        '192.168.1.79', 'admin', ''), throwsA(isA<LumaNvrException>()));
  });

  test('camera channel stream and snapshot paths use N01', () {
    expect(lumaSnapshotPath(1),
        '/ISAPI/Streaming/channels/101/picture');
    expect(lumaPreviewPath(9),
        '/ISAPI/Streaming/channels/901/httpPreview');
    expect(lumaSnapshotPath(64),
        '/ISAPI/Streaming/channels/6401/picture');
    expect(() => lumaPreviewPath(0), throwsA(isA<LumaNvrException>()));
    expect(() => lumaSnapshotPath(65), throwsA(isA<LumaNvrException>()));
  });

  test('device info parses namespace, model, firmware and serial', () {
    final info = parseLumaDeviceInfo(infoXml);
    expect(info.name, 'Family NVR');
    expect(info.model, 'Luma 500');
    expect(info.firmware, 'V4.2');
    expect(info.serial, 'TEST-123');
  });

  test('channels join online status and sort by numeric channel id', () {
    final cameras = parseLumaCameras(channelXml, statusXml);
    expect(cameras.length, 2);
    expect(cameras.first.channel, 1);
    expect(cameras.first.name, 'Driveway & Yard');
    expect(cameras.first.online, true);
    expect(cameras.last.channel, 2);
    expect(cameras.last.online, false);
    expect(parseLumaCameras(channelXml, null).first.online, isNull);
  });

  test('XML escaping prevents injection in settings changes', () {
    expect(lumaXmlEscape('a&b<c>"d' "'"),
        'a&amp;b&lt;c&gt;&quot;d&apos;');
  });

  test('PUT success requires statusCode 1 and surfaces NVR error', () {
    validateLumaPut('<ResponseStatus><statusCode>1</statusCode>'
        '</ResponseStatus>');
    expect(() => validateLumaPut(
        '<ResponseStatus><statusCode>4</statusCode>'
        '<statusString>Invalid Operation</statusString></ResponseStatus>'),
        throwsA(isA<LumaNvrException>()));
  });

  test('recorder settings parser preserves time and network fields', () {
    final fields = parseLumaFields(
      '<Time><timeMode>NTP</timeMode><timeZone>EST+5:00:00</timeZone></Time>',
      ['timeMode', 'timeZone']);
    expect(fields['timeMode'], 'NTP');
    expect(fields['timeZone'], 'EST+5:00:00');
  });
}
