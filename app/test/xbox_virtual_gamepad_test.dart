import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/xbox_virtual_gamepad.dart';

void main() {
  test('Xbox standard controller mappings are correct', () {
    expect(XboxVirtualGamepad.buttonA, 0);
    expect(XboxVirtualGamepad.buttonB, 1);
    expect(XboxVirtualGamepad.buttonX, 2);
    expect(XboxVirtualGamepad.buttonY, 3);
    expect(XboxVirtualGamepad.view, 8);
    expect(XboxVirtualGamepad.menu, 9);
    expect(XboxVirtualGamepad.up, 12);
    expect(XboxVirtualGamepad.down, 13);
    expect(XboxVirtualGamepad.left, 14);
    expect(XboxVirtualGamepad.right, 15);
    expect(XboxVirtualGamepad.guide, 16);
  });

  test('button events are bounded and release is explicit', () {
    final press = XboxVirtualGamepad.buttonScript(
        XboxVirtualGamepad.buttonA, true);
    final release = XboxVirtualGamepad.buttonScript(
        XboxVirtualGamepad.buttonA, false);
    expect(press, contains('pad.button(0,true)'));
    expect(release, contains('pad.button(0,false)'));
    expect(XboxVirtualGamepad.releaseScript, contains('releaseAll'));
    expect(() => XboxVirtualGamepad.buttonScript(-1, true),
        throwsArgumentError);
    expect(() => XboxVirtualGamepad.buttonScript(99, true),
        throwsArgumentError);
    expect(() => XboxVirtualGamepad.buttonScript(6, true),
        throwsArgumentError);
  });

  test('injection works only on Microsoft Xbox HTTPS origins', () {
    expect(XboxVirtualGamepad.isMicrosoftXboxPage(
        'https://www.xbox.com/remoteplay'), true);
    expect(XboxVirtualGamepad.isMicrosoftXboxPage(
        'https://xbox.com/play'), true);
    expect(XboxVirtualGamepad.isMicrosoftXboxPage(
        'https://login.microsoftonline.com'), false);
    expect(XboxVirtualGamepad.isMicrosoftXboxPage(
        'https://www.xbox.com.attacker.example/remoteplay'), false);
    expect(XboxVirtualGamepad.isMicrosoftXboxPage(
        'http://www.xbox.com/remoteplay'), false);
  });

  test('bootstrap is only an experimental page-level Gamepad API', () {
    expect(XboxVirtualGamepad.bootstrap, contains('navigator'));
    expect(XboxVirtualGamepad.bootstrap, contains('getGamepads'));
    expect(XboxVirtualGamepad.bootstrap, contains('window.__tapTetherVirtualGamepad'));
    expect(XboxVirtualGamepad.bootstrap, contains('releaseAll'));
    expect(XboxVirtualGamepad.bootstrap, isNot(contains('xbl.io')));
  });
}
