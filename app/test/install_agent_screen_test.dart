import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/install_agent_screen.dart';
import 'package:taptether/ssh_provisioner.dart';

void main() {
  testWidgets('known Mac defaults to SSH installer, not a manual download',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: InstallAgentScreen(
      initialHost: '192.168.68.77',
      knownPlatform: 'darwin',
      onInstalled: (InstalledAgent installed, String platform) async => true,
    )));
    await tester.pump();
    expect(find.text('Install Agent'), findsOneWidget);
    expect(find.text('Install Mac over SSH'), findsOneWidget);
    expect(find.text('Manual macOS download (optional)'), findsOneWidget);
    expect(find.text('Install over SSH'), findsNothing);
  });

  testWidgets('updating a saved Mac uses the same SSH pathway',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: InstallAgentScreen(
      initialHost: '192.168.68.77',
      knownPlatform: 'darwin',
      updateOnly: true,
      onInstalled: (InstalledAgent installed, String platform) async => true,
    )));
    await tester.pump();
    expect(find.text('Update Agent'), findsOneWidget);
    expect(find.text('Update Mac over SSH'), findsOneWidget);
    expect(find.text('Install Mac over SSH'), findsNothing);
  });

  testWidgets('Ubuntu update uses SSH and never treats Windows as Linux',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: InstallAgentScreen(
      initialHost: '192.168.68.87',
      knownPlatform: 'linux',
      updateOnly: true,
      onInstalled: (InstalledAgent installed, String platform) async => true,
    )));
    await tester.pump();
    expect(find.text('Update over SSH'), findsOneWidget);
    expect(find.text('Update Mac over SSH'), findsNothing);
  });
}
