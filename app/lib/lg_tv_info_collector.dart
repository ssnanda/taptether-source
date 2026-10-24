import 'lg_webos_client.dart';
import 'lg_tv_metadata.dart';

/// Optional read-only facts from a TV already paired on the local network.
/// Unsupported services are normal and do not affect remote control.
Future<Map<String, String>> readLgTvSystemDetails(LgWebOsClient client) async {
  if (!client.connected) return const {};
  Future<Map<String, String>> probe(String source, String uri,
      [Map<String, Object> parameters = const {}]) async {
    try {
      final info = await client.request(uri, parameters)
          .timeout(const Duration(seconds: 3));
      return lgTvMetadataFromPayload(source, info);
    } catch (_) {
      return const {};
    }
  }

  // The systemproperty service requires a keys array. This was missing
  // from the previous model/firmware collector.
  final entries = await Future.wait([
    probe('system', 'ssap://system/getSystemInfo'),
    probe('system', 'ssap://com.webos.service.tv.systemproperty/getSystemInfo',
        {'keys': <String>['modelName', 'firmwareVersion',
            'sdkVersion', 'boardType', 'UHD', '_3d']}),
    probe('software',
        'ssap://com.webos.service.update/getCurrentSWInformation'),
    probe('inputs', 'ssap://tv/getExternalInputList'),
  ]);
  final output = <String, String>{};
  for (final item in entries) {
    output.addAll(item);
  }
  if (output.isNotEmpty) {
    output['Last checked'] = DateTime.now().toUtc().toIso8601String();
  }
  return output;
}
