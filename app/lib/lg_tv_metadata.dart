/// Narrow, privacy-safe extraction of LG webOS SSAP read-only metadata.
///
/// Only documented, explicitly returned values are displayed. This avoids
/// guessing model capabilities and never saves serials, tokens or raw JSON.
Map<String, String> lgTvMetadataFromPayload(
    String source, Map<String, dynamic> payload) {
  final out = <String, String>{};

  void save(String key, Object? raw, {int limit = 100}) {
    if (raw is! String && raw is! num && raw is! bool) return;
    final value = raw.toString().trim();
    if (value.isEmpty || value.length > limit ||
        value.contains(RegExp(r'[\x00-\x1F]'))) return;
    out[key] = value;
  }

  void first(String label, List<String> keys) {
    for (final key in keys) {
      final raw = payload[key];
      if (raw is String && raw.trim().isNotEmpty) {
        save(label, raw);
        if (out.containsKey(label)) return;
      } else if (raw is num) {
        save(label, raw);
        return;
      }
    }
  }

  void capability(String label, String key) {
    final raw = payload[key];
    if (raw == null) return;
    if (raw == true || raw.toString().toLowerCase() == 'true') {
      out[label] = 'Supported';
    } else if (raw == false || raw.toString().toLowerCase() == 'false') {
      out[label] = 'Not supported';
    }
  }

  switch (source) {
    case 'system':
      first('Model', ['modelName', 'model_name', 'model']);
      first('Product', ['productName', 'product_name']);
      first('Firmware', ['firmwareVersion', 'firmware_version']);
      first('webOS SDK', ['sdkVersion']);
      first('webOS version', ['webOSVersion', 'webosVersion']);
      first('Chipset / region', ['boardType']);
      capability('4K UHD', 'UHD');
      capability('3D playback', '_3d');
      break;
    case 'software':
      first('Model', ['model_name', 'modelName']);
      first('Product', ['product_name', 'productName']);
      first('Firmware', ['sw_version']);
      first('webOS version', ['webos_version', 'webOSVersion']);
      first('Software type', ['sw_type']);
      break;
    case 'inputs':
      final devices = payload['devices'];
      if (devices is List) {
        // Count only known entries; do not save app IDs, icons or URLs.
        final ports = devices.whereType<Map>().where((item) =>
            item['id']?.toString().startsWith('HDMI_') == true).toList();
        if (ports.isNotEmpty) {
          out['HDMI inputs'] = ports.length.toString();
          final names = ports.where((item) => item['connected'] == true)
              .map((item) => item['label']?.toString() ?? '')
              .where((value) => value.isNotEmpty && value.length <= 36)
              .take(4).toList();
          if (names.isNotEmpty) {
            out['Connected HDMI'] = names.join(', ');
          }
        }
      }
      break;
    case 'audio':
      first('Sound output', ['soundOutput', 'output']);
      break;
    case 'power':
      first('Power state', ['state']);
      break;
    case 'app':
      first('Foreground app', ['appId']);
      break;
  }
  return out;
}
