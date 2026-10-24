import 'lg_webos_client.dart';
import 'lg_tv_metadata.dart';

Future<Map<String, String>> readLgTvSystemDetails(LgWebOsClient client) async {
  if (!client.connected) return const {};
  final info = await client.request(
    'ssap://com.webos.service.tv.systemproperty/getSystemInfo',
    {'keys': <String>['modelName', 'firmwareVersion', 'sdkVersion', 'UHD']},
  );
  return lgTvMetadataFromPayload('system', info);
}
