import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/presentation_mode.dart';

void main() {
  test('presentation key mappings work with the desktop agents', () {
    expect(PresentationShortcuts.next, 'Right');
    expect(PresentationShortcuts.previous, 'Left');
    expect(PresentationShortcuts.stop, 'Escape');
    expect(PresentationShortcuts.blankToggle, 'b');
    expect(PresentationShortcuts.start(PresentationApp.keynote, isMac: true),
        'alt+cmd+p');
    expect(PresentationShortcuts.start(PresentationApp.keynote, isMac: false),
        isNull);
    expect(PresentationShortcuts.start(PresentationApp.powerPoint, isMac: true),
        'cmd+shift+return');
    expect(PresentationShortcuts.start(PresentationApp.powerPoint, isMac: false),
        'f5');
    expect(PresentationShortcuts.start(PresentationApp.googleSlides, isMac: true),
        'cmd+shift+return');
    expect(PresentationShortcuts.start(PresentationApp.googleSlides, isMac: false),
        'ctrl+f5');
  });

  testWidgets('remote buttons send the expected keyboard commands',
      (tester) async {
    final pressed = <String>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SingleChildScrollView(child: PresentationControls(
        app: PresentationApp.powerPoint,
        isMac: false,
        enabled: true,
        landscape: false,
        onAppChanged: (_) {},
        onKey: pressed.add,
      )),
    )));
    await tester.tap(find.byKey(const ValueKey('slide-next')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('slide-previous')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('slide-start')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('slide-blank')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('slide-stop')));
    await tester.pump();
    expect(pressed, ['Right', 'Left', 'f5', 'b', 'Escape']);
    expect(find.textContaining('speaker notes'), findsOneWidget);
  });

  testWidgets('Keynote is not offered for Ubuntu', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      PresentationControls(
        app: PresentationApp.googleSlides,
        isMac: false,
        enabled: true,
        landscape: true,
        onAppChanged: (_) {},
        onKey: (_) {},
      ),
    )));
    await tester.tap(find.byKey(const ValueKey('presentation-app')));
    await tester.pumpAndSettle();
    expect(find.text('Keynote'), findsNothing);
  });

  testWidgets('control buttons disabled when connection is lost',
      (tester) async {
    var commands = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      PresentationControls(
        app: PresentationApp.keynote,
        isMac: true,
        enabled: false,
        landscape: false,
        onAppChanged: (_) {},
        onKey: (_) => commands++,
      ),
    )));
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('slide-next')));
    expect(button.onPressed, isNull);
    expect(commands, 0);
  });
}
