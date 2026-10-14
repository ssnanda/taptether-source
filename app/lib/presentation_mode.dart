import 'package:flutter/material.dart';

/// Keystroke-only presentation remote. No slide inspection, screenshots,
/// speaker notes, internet access, or integration with presentation files.
enum PresentationApp { powerPoint, googleSlides, keynote }

extension PresentationAppLabel on PresentationApp {
  String get label => switch (this) {
    PresentationApp.powerPoint => 'PowerPoint',
    PresentationApp.googleSlides => 'Google Slides',
    PresentationApp.keynote => 'Keynote',
  };
}

class PresentationShortcuts {
  const PresentationShortcuts._();

  static const next = 'Right';
  static const previous = 'Left';
  static const stop = 'Escape';
  static const blankToggle = 'b';

  /// Shortcuts start a presentation in the foreground editor.
  /// Null means the selected app isn't supported on this platform.
  static String? start(PresentationApp app, {required bool isMac}) {
    switch (app) {
      case PresentationApp.keynote:
        return isMac ? 'alt+cmd+p' : null;
      case PresentationApp.powerPoint:
        // PowerPoint desktop on Mac, PowerPoint web on Ubuntu.
        return isMac ? 'cmd+shift+return' : 'ctrl+f5';
      case PresentationApp.googleSlides:
        // Google Slides in a foreground browser, from the beginning.
        return isMac ? 'cmd+shift+return' : 'ctrl+f5';
    }
  }
}

/// A dedicated, large-touch-target slideshow remote. The computer's active
/// presentation application must be in the foreground to receive commands.
class PresentationControls extends StatelessWidget {
  const PresentationControls({
    super.key,
    required this.app,
    required this.isMac,
    required this.enabled,
    required this.landscape,
    required this.onAppChanged,
    required this.onKey,
  });

  final PresentationApp app;
  final bool isMac;
  final bool enabled;
  final bool landscape;
  final ValueChanged<PresentationApp> onAppChanged;
  final ValueChanged<String> onKey;

  Widget _sendButton({
    required String label,
    required IconData icon,
    required String? key,
    bool prominent = false,
    Key? widgetKey,
  }) {
    final action = enabled && key != null ? () => onKey(key) : null;
    return SizedBox(
      height: landscape ? 60 : 78,
      child: prominent
          ? FilledButton.icon(
              key: widgetKey,
              onPressed: action,
              icon: Icon(icon, size: 26),
              label: Text(label, textAlign: TextAlign.center),
            )
          : OutlinedButton.icon(
              key: widgetKey,
              onPressed: action,
              icon: Icon(icon, size: 22),
              label: Text(label, textAlign: TextAlign.center),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final startKey = PresentationShortcuts.start(app, isMac: isMac);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<PresentationApp>(
          key: const ValueKey('presentation-app'),
          initialValue: app,
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.slideshow_outlined),
            labelText: 'Presenting with',
          ),
          items: [
            for (final choice in PresentationApp.values)
              if (isMac || choice != PresentationApp.keynote)
                DropdownMenuItem(value: choice, child: Text(choice.label)),
          ],
          onChanged: (choice) {
            if (choice != null) onAppChanged(choice);
          },
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-previous'),
            label: 'Previous',
            icon: Icons.arrow_back,
            key: PresentationShortcuts.previous,
            prominent: true,
          )),
          const SizedBox(width: 12),
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-next'),
            label: 'Next',
            icon: Icons.arrow_forward,
            key: PresentationShortcuts.next,
            prominent: true,
          )),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-start'),
            label: 'Start',
            icon: Icons.play_arrow,
            key: startKey,
          )),
          const SizedBox(width: 8),
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-blank'),
            label: 'Blank / Restore',
            icon: Icons.tv_off_outlined,
            key: PresentationShortcuts.blankToggle,
          )),
          const SizedBox(width: 8),
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-stop'),
            label: 'End (Esc)',
            icon: Icons.stop_circle_outlined,
            key: PresentationShortcuts.stop,
          )),
        ]),
        const SizedBox(height: 10),
        Text(
          'Keep the slideshow app in the foreground. Commands control '
          'the computer keyboard; TapTether cannot read its current slide '
          'or speaker notes.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
