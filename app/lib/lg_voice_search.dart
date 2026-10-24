import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Single session shared across opening and closing the voice search sheet.
/// Recognition is started only by the user's microphone action.
final stt.SpeechToText _recognizer = stt.SpeechToText();

/// Dictation uses the phone's configured speech service. Some iOS/Android
/// speech services process audio on their servers. TapTether does not store
/// audio and sends only approved text to the paired TV over the LAN.
class LgVoiceSearchSheet extends StatefulWidget {
  const LgVoiceSearchSheet({super.key, required this.onSend});

  final Future<void> Function(String text) onSend;

  @override
  State<LgVoiceSearchSheet> createState() => _LgVoiceSearchSheetState();
}

class _LgVoiceSearchSheetState extends State<LgVoiceSearchSheet> {
  String _transcript = '';
  String? _error;
  bool _listening = false;
  bool _sending = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  Future<void> _begin() async {
    if (_starting || _sending || _listening) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final ready = await _recognizer.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'done' || status == 'notListening') {
            setState(() => _listening = false);
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _error = 'Speech recognition stopped: ${error.errorMsg}';
            _listening = false;
          });
        },
      );
      if (!mounted) return;
      if (!ready) {
        setState(() => _error =
            'Speech recognition is unavailable or permission was denied. '
            'You can use the keyboard button instead.');
        return;
      }
      await _recognizer.listen(
        onResult: (result) {
          if (!mounted) return;
          setState(() => _transcript = result.recognizedWords);
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
      );
      if (mounted) setState(() => _listening = _recognizer.isListening);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not start speech recognition. Check microphone access.');
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    try {
      await _recognizer.stop();
    } catch (_) {
      // The device may stop recognition automatically after a pause.
    }
    if (mounted) setState(() => _listening = false);
  }

  Future<void> _send() async {
    if (_sending) return;
    await _stop();
    if (!mounted) return;
    final text = _transcript.trim();
    if (text.isEmpty || text.length > 500) {
      setState(() => _error = 'Speak a short search phrase (500 characters max).');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onSend(text);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'The TV did not accept the text. Open a search field in the '
            'TV app and try again. Some apps block remote text entry.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    unawaited(_recognizer.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20, 8, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.mic_none),
              const SizedBox(width: 10),
              Expanded(child: Text('Voice search',
                  style: Theme.of(context).textTheme.titleLarge)),
              IconButton(
                tooltip: 'Close voice search',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
            const SizedBox(height: 8),
            Text(_starting
                ? 'Requesting microphone access…'
                : _listening ? 'Listening on this phone…'
                : 'Open a search field on your TV, then send the words below.'),
            const SizedBox(height: 12),
            Container(
              key: const ValueKey('lg-voice-transcript'),
              constraints: const BoxConstraints(minHeight: 72),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(14),
              child: Text(_transcript.isEmpty
                  ? 'Your spoken words will appear here.'
                  : _transcript,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: 9),
            Text('Uses your phone’s speech recognition, which may use '
                'an online service. Only text you approve is sent to '
                'the TV over your local network.',
                style: Theme.of(context).textTheme.bodySmall),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                key: const ValueKey('lg-voice-listen'),
                onPressed: _starting || _sending
                    ? null : _listening ? _stop : _begin,
                icon: Icon(_listening ? Icons.stop : Icons.mic),
                label: Text(_listening ? 'Stop' : 'Speak again'),
              )),
              const SizedBox(width: 10),
              Expanded(child: FilledButton.icon(
                key: const ValueKey('lg-voice-send'),
                onPressed: _sending || _transcript.trim().isEmpty
                    ? null : _send,
                icon: const Icon(Icons.send),
                label: Text(_sending ? 'Sending…' : 'Send to TV'),
              )),
            ]),
          ],
        ),
      ),
    );
  }
}
