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
    expect(MediaSearch.searchPageUrl(MediaService.netflix),
        'https://www.netflix.com/search');
    expect(MediaSearch.searchPageUrl(MediaService.youtube),
        'https://www.youtube.com/results?search_query=');
    expect(MediaSearch.browseUrl(MediaService.netflix),
        'https://www.netflix.com/browse');
    expect(() => MediaSearch.url(MediaService.youtube, ''),
        throwsFormatException);
    expect(() => MediaSearch.url(MediaService.netflix, List.filled(80, 'a').join()),
        throwsFormatException);
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
        onSearchPage: (_) async {},
      )),
    )));
    expect(tester.widget<TextField>(
        find.byKey(const ValueKey('media-search-text'))).enabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('media-search-page')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('media-search-text')),
        'example movie');
    await tester.tap(find.byKey(const ValueKey('media-search-submit')));
    await tester.pump();
    expect(searched, MediaService.netflix);
    expect(query, 'example movie');
    expect(tester.widget<TextField>(
        find.byKey(const ValueKey('media-search-text'))).enabled, isFalse);
  });

  testWidgets('back to browsing, profile and close are explicit',
      (tester) async {
    final actions = <String>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SingleChildScrollView(child: MediaRemote(
        service: MediaService.netflix, enabled: true, landscape: false,
        onServiceChanged: (_) {},
        onKey: (_) {},
        onSearch: (_, __) async {},
        onExitVideo: (_, __) async { actions.add('back'); },
        onProfile: (_) async { actions.add('profile'); },
        onCloseService: (_) async { actions.add('close'); },
      )),
    )));
    await tester.tap(find.byKey(const ValueKey('media-exit-video')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('media-profile')));
    await tester.tap(find.byKey(const ValueKey('media-profile')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('media-close')));
    await tester.tap(find.byKey(const ValueKey('media-close')));
    await tester.pumpAndSettle();
    expect(actions, ['back', 'profile']);
    await tester.tap(find.text('Close tab').last);
    await tester.pump();
    expect(actions, ['back', 'profile', 'close']);
  });
}
