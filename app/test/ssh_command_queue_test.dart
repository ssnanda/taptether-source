import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ssh_command_queue.dart';

void main() {
  test('sample cleanup is individual commands grouped by section', () {
    const pasted = r'''# Stop and disable services
sudo systemctl disable --now taptether-agent.service 2>/dev/null || true
systemctl --user disable --now taptether-agent.service taptether-screen.service 2>/dev/null || true

# Remove installed package
sudo dpkg --purge taptether-agent

# Remove system-level leftovers
sudo rm -f /etc/systemd/system/taptether-agent.service
sudo rm -f /etc/systemd/system/taptether-update.service
sudo rm -f /etc/systemd/system/taptether-agent.service.d/40-shutdown.conf
sudo rm -f /etc/polkit-1/rules.d/80-taptether-shutdown.rules
sudo rm -f /etc/polkit-1/rules.d/80-taptether-update.rules
sudo rm -f /etc/modules-load.d/taptether-uinput.conf
sudo rm -f /etc/udev/rules.d/80-taptether-uinput.rules
sudo rm -f /usr/local/libexec/taptether-update-ubuntu.sh
sudo rm -f /usr/local/bin/taptether-agent

# Remove user-level leftovers
rm -f ~/.config/systemd/user/taptether-agent.service
rm -f ~/.config/systemd/user/taptether-screen.service
rm -f ~/.config/autostart/taptether-{agent,tray,screen}.desktop
rm -f ~/.local/share/applications/taptether.desktop
rm -f ~/.local/bin/taptetherctl
rm -f ~/.local/bin/taptether-uninstall
rm -f ~/.local/bin/taptether-agent-update
rm -rf ~/.local/share/taptether
rm -rf ~/.cache/taptether

# Reload services
sudo systemctl daemon-reload
systemctl --user daemon-reload
sudo systemctl reset-failed taptether-agent.service''';
    final parsed = parseSshCommandQueue(pasted);
    expect(parsed, hasLength(24));
    expect(parsed.first.command,
        'sudo systemctl disable --now taptether-agent.service 2>/dev/null || true');
    expect(parsed.first.section, 'Stop and disable services');
    expect(parsed[2].command, 'sudo dpkg --purge taptether-agent');
    expect(parsed[2].section, 'Remove installed package');
    expect(parsed.last.command,
        'sudo systemctl reset-failed taptether-agent.service');
    expect(parsed.last.section, 'Reload services');
    expect(parsed.every((item) =>
        !item.command.trim().startsWith('#')), isTrue);
    expect(parsed.every((item) => !item.shellTransition), isTrue);
  });

  test('shell switches require explicit confirmation and keep context', () {
    final commands = parseSshCommandQueue(
        'pwd\nsudo su -\ncd /root\nwhoami');
    expect(commands, hasLength(4));
    expect(commands[1].shellTransition, isTrue);
    expect(commands[2].shellTransition, isFalse);
    expect(isSshShellTransition('sudo -i'), isTrue);
    expect(isSshShellTransition('sudo dpkg --purge name'), isFalse);
  });

  test('completion marker is safely quoted and parsed in fragments', () {
    const token = 'abcdef1234567890';
    final wrapped = wrapSshQueuedCommand(
        "echo 'hi there'; cd /tmp", token);
    expect(wrapped, contains('eval'));
    expect(wrapped, contains(r'''echo '"'"'hi there'"'"'; cd /tmp'''));
    expect(wrapped, contains('TT_DONE_$token'));

    final decoder = SshQueueOutputDecoder(token);
    expect(decoder.add('Installing...\n').output, 'Installing...\n');
    final beginning = decoder.add('\u001eTT_DONE_abcd');
    expect(beginning.output, isEmpty);
    expect(beginning.exitCode, isNull);
    final rest = decoder.add('ef1234567890:1\u001f\n');
    expect(rest.exitCode, 1);
    expect(rest.output, isEmpty);
  });

  test('invalid marker does not fake command completion', () {
    final decoder = SshQueueOutputDecoder('abcdef1234567890');
    final chunk = decoder.add('\u001eOTHER:0\u001f\n');
    expect(chunk.exitCode, isNull);
    expect(chunk.output, contains('OTHER'));
    expect(() => wrapSshQueuedCommand('pwd', 'guess'),
        throwsFormatException);
  });

  test('blank lines, heredocs and continuation lines remain intact', () {
    final commands = parseSshCommandQueue(
        '# First section\n'
        'echo first\n\n'
        'cat <<EOF\nhello\n\nworld\nEOF\n'
        'echo one \\\n  two\n');
    expect(commands, hasLength(3));
    expect(commands[0].section, 'First section');
    expect(commands[1].command, contains('\n\nworld\nEOF'));
    expect(commands[2].command, contains('\n  two'));
    expect(() => parseSshCommandQueue('cat <<EOF\nmissing'),
        throwsFormatException);
  });
}
