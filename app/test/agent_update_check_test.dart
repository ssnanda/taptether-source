import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/agent_update_check.dart';

void main() {
  test('matching app and computer agent versions do not trigger an update', () {
    const check = AgentUpdateCheck(
      installed: '0.6.12+55',
      published: '0.6.12+55',
    );
    expect(check.state, AgentUpdateState.upToDate);
    expect(check.canUpdate, isFalse);
    expect(check.description, contains('already up to date'));
  });

  test('newer release offers update; newer installed build does not downgrade', () {
    expect(const AgentUpdateCheck(
      installed: '0.6.12+53', published: '0.6.12+56',
    ).canUpdate, isTrue);
    expect(const AgentUpdateCheck(
      installed: '0.6.12+56', published: '0.6.12+55',
    ).state, AgentUpdateState.upToDate);
  });

  test('unknown and malformed versions do not authorize an update', () {
    expect(const AgentUpdateCheck(
      installed: null, published: '0.6.12+56',
    ).state, AgentUpdateState.unavailable);
    expect(const AgentUpdateCheck(
      installed: 'broken', published: '0.6.12+56',
    ).canUpdate, isFalse);
    expect(const AgentUpdateCheck(
      installed: '0.6.12+54', published: null,
    ).canUpdate, isFalse);
  });

  test('macOS permission failure is identified without treating pings as proof', () {
    expect(isMacAccessibilityError(StateError(
      'Agent response 422: TapTether needs macOS Accessibility permission: '
      'System Settings > Privacy & Security > Accessibility',
    )), isTrue);
    expect(isMacAccessibilityError(StateError('Agent response 500')), isFalse);
  });

  testWidgets('up-to-date agent dialog shows versions but no Update button',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: AgentUpdateDialog(
        computerName: 'MacBook',
        check: AgentUpdateCheck(
          installed: '0.6.12+55',
          published: '0.6.12+55',
        ),
      ),
    )));
    expect(find.text('Installed version'), findsOneWidget);
    expect(find.text('Latest published version'), findsOneWidget);
    expect(tester.widget<SelectableText>(
        find.byKey(const ValueKey('agent-installed-version'))).data,
        '0.6.12+55');
    expect(tester.widget<SelectableText>(
        find.byKey(const ValueKey('agent-published-version'))).data,
        '0.6.12+55');
    expect(find.text('Close'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-agent-update')), findsNothing);
  });

  testWidgets('update dialog displays different versions and Update action',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: AgentUpdateDialog(
        computerName: 'MacBook',
        check: AgentUpdateCheck(
          installed: '0.6.12+53',
          published: '0.6.12+56',
        ),
      ),
    )));
    expect(tester.widget<SelectableText>(
        find.byKey(const ValueKey('agent-installed-version'))).data,
        '0.6.12+53');
    expect(tester.widget<SelectableText>(
        find.byKey(const ValueKey('agent-published-version'))).data,
        '0.6.12+56');
    expect(find.byKey(const ValueKey('confirm-agent-update')), findsOneWidget);
  });
}
