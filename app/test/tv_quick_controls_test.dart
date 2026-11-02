import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_webos_client.dart';
import 'package:taptether/tv_quick_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native TV quick control bridge safely skips non-iOS platforms', () async {
    if (Platform.isIOS) return;
    TvQuickControls.instance.initialize();
    await TvQuickControls.instance.consumePending();
    await TvQuickControls.instance.select(
      const LgTvDevice(
        host: '192.168.68.77',
        name: 'Family Room TV',
        clientKey: 'paired',
      ), connected: false,
    );
  });
}
