import 'package:flutter/material.dart';

/// Consumer video playback is a separate mode from presentation controls.
/// Commands are sent only to the already-authenticated desktop agent.
enum MediaService { youtube, netflix }

extension MediaServiceLabel on MediaService {
  String get label => switch (this) {
    MediaService.youtube => 'YouTube',
    MediaService.netflix => 'Netflix',
  };
}

/// Generates only two fixed, allowlisted browser search destinations.
/// The generated URL is typed into the foreground browser on the computer.
class MediaSearch {
  const MediaSearch._();

  static String searchPageUrl(MediaService service) => switch (service) {
    MediaService.netflix => 'https://www.netflix.com/search',
    MediaService.youtube => 'https://www.youtube.com/results?search_query=',
  };

  static String browseUrl(MediaService service) => switch (service) {
    MediaService.netflix => 'https://www.netflix.com/browse',
    MediaService.youtube => 'https://www.youtube.com/',
  };

  static String url(MediaService service, String search) {
    final query = search.trim();
    if (query.isEmpty) {
      throw const FormatException('Enter a video title or search phrase.');
    }
    if (query.runes.length > 70 || query.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const FormatException('Keep your video search under 70 characters.');
    }
    final uri = switch (service) {
      MediaService.youtube => Uri.https(
          'www.youtube.com', '/results', {'search_query': query}),
      MediaService.netflix => Uri.https(
          'www.netflix.com', '/search', {'q': query}),
    };
    final destination = uri.toString();
    if (destination.length > 256) {
      throw const FormatException('Search too long for desktop typing.');
    }
    return destination;
  }
}

class MediaRemote extends StatefulWidget {
  const MediaRemote({
    super.key,
    required this.service,
    required this.enabled,
    required this.landscape,
    required this.onServiceChanged,
    required this.onKey,
    required this.onSearch,
    this.onOpenService,
    this.onSearchPage,
    this.onExitVideo,
    this.onProfile,
    this.onCloseService,
  });

  final MediaService service;
  final bool enabled;
  final bool landscape;
  final ValueChanged<MediaService> onServiceChanged;
  final ValueChanged<String> onKey;
  final Future<void> Function(MediaService, String) onSearch;
  final Future<void> Function(MediaService)? onOpenService;
  final Future<void> Function(MediaService)? onSearchPage;
  final Future<void> Function(MediaService)? onExitVideo;
  final Future<void> Function(MediaService)? onProfile;
  final Future<void> Function(MediaService)? onCloseService;

  @override
  State<MediaRemote> createState() => _MediaRemoteState();
}

class _MediaRemoteState extends State<MediaRemote> {
  final _search = TextEditingController();
  bool _searching = false;
  bool _searchReady = false;

  @override
  void didUpdateWidget(covariant MediaRemote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service ||
        (oldWidget.enabled && !widget.enabled)) {
      _searchReady = false;
      _search.clear();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _error(Object error) {
    if (!mounted) return;
    final message = error is FormatException
        ? error.message : error.toString();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)));
  }

  Future<void> _openSearchPage() async {
    if (!widget.enabled || _searching || widget.onSearchPage == null) return;
    setState(() { _searchReady = false; _searching = true; });
    try {
      await widget.onSearchPage!(widget.service);
      if (mounted) setState(() => _searchReady = true);
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _submitSearch() async {
    if (!widget.enabled || _searching || !_searchReady) return;
    setState(() => _searching = true);
    try {
      MediaSearch.url(widget.service, _search.text);
      await widget.onSearch(widget.service, _search.text);
      // Explicitly re-arm Search for the next query. TapTether cannot
      // detect whether a viewer has entered a video in this browser tab.
      if (mounted) setState(() => _searchReady = false);
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _goBack() async {
    if (!widget.enabled || _searching || widget.onExitVideo == null) return;
    setState(() { _searching = true; _searchReady = false; });
    try {
      await widget.onExitVideo!(widget.service);
    } catch (error) { _error(error); }
    finally { if (mounted) setState(() => _searching = false); }
  }

  Future<void> _chooseProfile() async {
    if (!widget.enabled || _searching || widget.onProfile == null) return;
    setState(() { _searching = true; _searchReady = false; });
    try { await widget.onProfile!(widget.service); }
    catch (error) { _error(error); }
    finally { if (mounted) setState(() => _searching = false); }
  }

  Future<void> _closeTab() async {
    if (!widget.enabled || _searching || widget.onCloseService == null) return;
    final shouldClose = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Close ${widget.service.label} tab?'),
        content: const Text('This closes the currently focused browser '
            'tab on your computer. TapTether cannot verify its URL. '
            'You will remain signed in.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Close tab')),
        ],
      ),
    );
    if (shouldClose != true || !mounted) return;
    setState(() { _searching = true; _searchReady = false; });
    try { await widget.onCloseService!(widget.service); }
    catch (error) { _error(error); }
    finally { if (mounted) setState(() => _searching = false); }
  }

  Widget _button(String label, IconData icon, String key, {Key? buttonKey}) {
    return OutlinedButton.icon(
      key: buttonKey,
      onPressed: widget.enabled ? () => widget.onKey(key) : null,
      icon: Icon(icon),
      label: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<MediaService>(
        key: const ValueKey('media-provider-selector'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: MediaService.youtube,
              label: Text('YouTube'), icon: Icon(Icons.play_circle_outline)),
          ButtonSegment(value: MediaService.netflix,
              label: Text('Netflix'), icon: Icon(Icons.movie_outlined)),
        ],
        selected: {widget.service},
        onSelectionChanged: (selection) =>
            widget.onServiceChanged(selection.first),
      ),
      if (widget.onOpenService != null)
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          key: const ValueKey('media-open-provider'),
          onPressed: widget.enabled && !_searching ? () {
            setState(() => _searchReady = false);
            widget.onOpenService!(widget.service).catchError(_error);
          } : null,
          icon: const Icon(Icons.open_in_browser),
          label: Text('Open ${widget.service.label} on computer'),
        )),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const ValueKey('media-search-page'),
        onPressed: widget.enabled && !_searching ? _openSearchPage : null,
        icon: const Icon(Icons.manage_search),
        label: Text('Go to ${widget.service.label} search page'),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('media-search-text'),
        controller: _search,
        enabled: widget.enabled && !_searching && _searchReady,
        autocorrect: false,
        decoration: InputDecoration(
          isDense: true,
          labelText: _searchReady ? 'Search ${widget.service.label} videos' : 'Open search page first',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            key: const ValueKey('media-search-submit'),
            tooltip: 'Search in current computer tab',
            onPressed: widget.enabled && !_searching && _searchReady ? _submitSearch : null,
            icon: const Icon(Icons.arrow_forward),
          ),
        ),
        onSubmitted: (_) => _submitSearch(),
      ),
      const SizedBox(height: 6),
      Text('Search navigates within the focused browser tab. '
          'It never opens a new search tab.',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8,
        children: [
          if (widget.onExitVideo != null)
            OutlinedButton.icon(
              key: const ValueKey('media-exit-video'),
              onPressed: widget.enabled && !_searching ? _goBack : null,
              icon: const Icon(Icons.arrow_back),
              label: Text(widget.service == MediaService.netflix
                  ? 'Exit video / Browse' : 'Back to YouTube'),
            ),
          _button('Rewind', Icons.replay_10, 'Left'),
          _button('Play / Pause', Icons.play_arrow, 'space',
              buttonKey: const ValueKey('media-play-pause')),
          _button('Skip ahead', Icons.forward_10, 'Right'),
          _button('Full screen', Icons.fullscreen, 'f'),
          _button('Exit full screen', Icons.fullscreen_exit, 'Escape'),
          if (widget.service == MediaService.youtube) ...[
            _button('Next video', Icons.skip_next, 'shift+n'),
            _button('Captions', Icons.closed_caption, 'c'),
          ],
        ],
      ),
      const SizedBox(height: 12),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8,
        children: [
          _button('Lower', Icons.volume_down, 'XF86AudioLowerVolume',
              buttonKey: const ValueKey('media-volume-down')),
          _button('Mute', Icons.volume_off, 'XF86AudioMute'),
          _button('Raise', Icons.volume_up, 'XF86AudioRaiseVolume',
              buttonKey: const ValueKey('media-volume-up')),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8,
        children: [
          if (widget.onProfile != null)
            OutlinedButton.icon(
              key: const ValueKey('media-profile'),
              onPressed: widget.enabled && !_searching ? _chooseProfile : null,
              icon: const Icon(Icons.account_circle_outlined),
              label: Text(widget.service == MediaService.netflix
                  ? 'Choose profile' : 'Switch account'),
            ),
          if (widget.onCloseService != null)
            OutlinedButton.icon(
              key: const ValueKey('media-close'),
              onPressed: widget.enabled && !_searching ? _closeTab : null,
              icon: const Icon(Icons.close),
              label: Text('Close ${widget.service.label} tab'),
            ),
        ],
      ),
    ]);
  }
}
