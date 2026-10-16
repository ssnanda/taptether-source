import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/media_remote.dart';
import 'package:taptether/visual_mode.dart';

void main() {
  test('video search is allowlisted and safely URL-encoded', () {
    expect(MediaSearch.url(MediaService.youtube, 'cats & dogs'),
        'https://www.youtube.com/results?search_query=cats+%26+dogs');
    expect(MediaSearch.url(MediaService.netflix, 'star wars'),
        'https://www.netflix.com/search?q=star+wars');
    expect(() => MediaSearch.url(MediaService.youtube, ''),
        throwsFormatException);
    expect(() => MediaSearch.url(MediaService.netflix, List.filled(80, 'a').join()),
        throwsFormatException);
  });

  test('capture UI stays usable if macOS/Windows capability info is stale', () {
    expect(VisualModePolicy.canRequestCapture(
        advertised: false, platform: 'darwin'), true);
    expect(VisualModePolicy.canRequestCapture(
        advertised: false, platform: 'windows'), true);
    expect(VisualModePolicy.canRequestCapture(
        advertised: false, platform: 'linux'), false);
    expect(VisualModePolicy.canRequestCapture(
        advertised: true, platform: 'linux'), true);
    expect(VisualModePolicy.canRequestCapture(
        advertised: false, platform: null), false);
  });

  test('snapshot cadence and mode normalization are stable', () {
    expect(VisualModePolicy.snapshotInterval, const Duration(seconds: 15));
    expect(VisualModePolicy.normalize('live'), 'live');
    expect(VisualModePolicy.normalize('anything-else'), 'trackpad');
  });

  testWidgets('media buttons dispatch ordinary agent keys', (tester) async {
    final commands = <String>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SingleChildScrollView(child: MediaRemote(
        service: MediaService.youtube, enabled: true, landscape: false,
        onServiceChanged: (_) {}, onKey: commands.add,
        onSearch: (_, __) async {},
      )),
    )));
    await tester.tap(find.byKey(const ValueKey('media-play-pause')));
    await tester.tap(find.byKey(const ValueKey('media-volume-up')));
    expect(commands, ['space', 'XF86AudioRaiseVolume']);
  });

  testWidgets('media search forwards provider and typed query', (tester) async {
    MediaService? searched;
    String? query;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SingleChildScrollView(child: MediaRemote(
        service: MediaService.netflix, enabled: true, landscape: false,
        onServiceChanged: (_) {}, onKey: (_) {},
        onSearch: (provider, text) async {
          searched = provider;
          query = text;
        },
      )),
    )));
    await tester.enterText(find.byKey(const ValueKey('media-search-text')),
        'example movie');
    await tester.tap(find.byKey(const ValueKey('media-search-submit')));
    await tester.pump();
    expect(searched, MediaService.netflix);
    expect(query, 'example movie');
  });
}
