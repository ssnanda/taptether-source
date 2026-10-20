import 'package:flutter/services.dart';
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

  static String profileUrl(MediaService service) => switch (service) {
    MediaService.netflix => 'https://www.netflix.com/profiles/manage',
    MediaService.youtube => 'https://www.youtube.com/',
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

/// Restricts copied Netflix/YouTube links to canonical first-party video URLs.
class MediaSharedLink {
  const MediaSharedLink._();
  static String destination(MediaService service, String input,
      {required bool play}) {
    final raw = input.trim();
    if (raw.length > 2048 || raw.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const FormatException('Paste a valid Netflix or YouTube link.');
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
        uri.hasPort || uri.fragment.isNotEmpty) {
      throw const FormatException('Only HTTPS video links are accepted.');
    }
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (service == MediaService.netflix) {
      if (uri.host != 'netflix.com' && uri.host != 'www.netflix.com') {
        throw const FormatException('Paste a Netflix share link.');
      }
      if (parts.length == 3 &&
          RegExp(r'^[a-z]{2}(-[a-z]{2})?$', caseSensitive: false)
              .hasMatch(parts.first)) {
        parts.removeAt(0);
      }
      if (parts.length != 2 ||
          (parts.first != 'title' && parts.first != 'watch') ||
          !RegExp(r'^\d{5,12}$').hasMatch(parts.last)) {
        throw const FormatException('Netflix link needs a title or watch ID.');
      }
      return 'https://www.netflix.com/${play ? 'watch' : 'title'}/${parts.last}';
    }
    final allowed = uri.host == 'www.youtube.com' ||
        uri.host == 'youtube.com' || uri.host == 'm.youtube.com';
    final short = uri.host == 'youtu.be';
    String? id;
    if (short && parts.length == 1) {
      id = parts.first;
    } else if (allowed && parts.length == 1 && parts.first == 'watch') {
      id = uri.queryParameters['v'];
    } else if (allowed && parts.length == 2 && parts.first == 'shorts') {
      id = parts.last;
    }
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) {
      throw const FormatException('Paste a YouTube video or Shorts link.');
    }
    return 'https://www.youtube.com/watch?v=$id';
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
    this.onFullscreen,
    this.onCloseService,
    this.onOpenLink,
  });

  final MediaService service;
  final bool enabled;
  final bool landscape;
  final ValueChanged<MediaService> onServiceChanged;
  final ValueChanged<String> onKey;
  final Future<void> Function(MediaService, String) onSearch;
  final Future<void> Function(MediaService)? onOpenService;
  final Future<void> Function(MediaService)? onSearchPage;
  final Future<void> Function(MediaService, String?)? onExitVideo;
  final Future<void> Function(MediaService)? onProfile;
  /// User-initiated browser/player fullscreen shortcuts, with browser focus.
  final Future<void> Function(MediaService, bool)? onFullscreen;
  final Future<void> Function(MediaService)? onCloseService;
  final Future<void> Function(MediaService, String)? onOpenLink;

  @override
  State<MediaRemote> createState() => _MediaRemoteState();
}

class _MediaRemoteState extends State<MediaRemote> {
  final _search = TextEditingController();
  final _link = TextEditingController();
  bool _searching = false;
  bool _searchReady = false;
  bool _linkReady = false;
  String? _lastSearch;

  @override
  void didUpdateWidget(covariant MediaRemote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service ||
        (oldWidget.enabled && !widget.enabled)) {
      _searchReady = false;
      _search.clear();
      _link.clear();
      _linkReady = false;
      _lastSearch = null;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _link.dispose();
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
      if (mounted) {
        setState(() {
          _searchReady = false;
          _lastSearch = _search.text.trim();
        });
      }
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
      await widget.onExitVideo!(widget.service, _lastSearch);
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

  Future<void> _setFullscreen(bool enter) async {
    if (!widget.enabled || _searching) return;
    if (widget.onFullscreen == null) {
      widget.onKey(enter ? 'f' : 'Escape');
      return;
    }
    setState(() => _searching = true);
    try {
      await widget.onFullscreen!(widget.service, enter);
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
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

  Future<void> _pasteLink() async {
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = clipboard?.text?.trim() ?? '';
      // Validate *before* placing it into the field; never transmit pasted
      // content other than allowlisted canonical video destinations.
      MediaSharedLink.destination(widget.service, raw, play: false);
      if (mounted) {
        setState(() {
          _link.text = raw;
          _linkReady = false;
        });
      }
    } catch (error) { _error(error); }
  }

  Future<void> _sendLink({required bool play}) async {
    if (!widget.enabled || _searching || widget.onOpenLink == null) return;
    setState(() => _searching = true);
    try {
      final canonical = MediaSharedLink.destination(widget.service,
          _link.text, play: play);
      await widget.onOpenLink!(widget.service, canonical);
      if (mounted) {
        setState(() {
          _searchReady = false;
          _lastSearch = null;
          _linkReady = play;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(play
              ? 'Watch link sent. If Firefox blocks autoplay, wait until '
                'the player loads and use Start / resume (not Paste again).'
              : 'Opened title details on computer.')));
      }
    } catch (error) { _error(error); }
    finally { if (mounted) setState(() => _searching = false); }
  }

  Widget _compact(String tooltip, IconData icon, String key,
      {Key? buttonKey, bool primary = false}) {
    return IconButton(
      key: buttonKey,
      tooltip: tooltip,
      icon: Icon(icon, size: primary ? 29 : 23),
      style: primary ? IconButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer) : null,
      onPressed: widget.enabled && !_searching ? () => widget.onKey(key) : null,
    );
  }

  Widget _button(String label, IconData icon, String key, {Key? buttonKey}) {
    return OutlinedButton.icon(
      key: buttonKey,
      onPressed: widget.enabled && !_searching ? () => widget.onKey(key) : null,
      icon: Icon(icon),
      label: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_searching;
    final netflix = widget.service == MediaService.netflix;
    final theme = Theme.of(context);
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
        onSelectionChanged: (set) => widget.onServiceChanged(set.first),
      ),
      const SizedBox(height: 4),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        if (widget.onOpenService != null)
          TextButton.icon(
            key: const ValueKey('media-open-provider'),
            onPressed: enabled ? () async {
              setState(() { _searching = true; _searchReady = false; });
              try { await widget.onOpenService!(widget.service); }
              catch (error) { _error(error); }
              finally { if (mounted) setState(() => _searching = false); }
            } : null,
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('Open on computer'),
          ),
        TextButton.icon(
          key: const ValueKey('media-search-page'),
          onPressed: enabled && widget.onSearchPage != null
              ? _openSearchPage : null,
          icon: Icon(_searchReady ? Icons.check_circle_outline
              : Icons.search, size: 18),
          label: Text(_searchReady ? 'Search ready' : 'Search page'),
        ),
      ]),
      TextField(
        key: const ValueKey('media-search-text'),
        controller: _search,
        enabled: enabled && _searchReady,
        autocorrect: false,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: _searchReady ? 'Search ${widget.service.label}'
              : 'Tap Search page above to search',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: IconButton(
            key: const ValueKey('media-search-submit'),
            tooltip: 'Search in current tab',
            icon: const Icon(Icons.arrow_forward),
            onPressed: enabled && _searchReady ? _submitSearch : null,
          ),
        ),
        onSubmitted: (_) => _submitSearch(),
      ),
      const SizedBox(height: 8),
      if (widget.onOpenLink != null)
        ExpansionTile(
          key: const ValueKey('media-link-expansion'),
            tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 6),
          leading: const Icon(Icons.link),
          title: Text('Play from shared ${widget.service.label} link'),
          subtitle: Text('Copy in ${widget.service.label}, then paste here',
              style: theme.textTheme.bodySmall),
          children: [
            Row(children: [
              Expanded(child: TextField(
                key: const ValueKey('media-link-text'),
                controller: _link,
                enabled: enabled,
                autocorrect: false,
                onChanged: (_) {
                  if (_linkReady) setState(() => _linkReady = false);
                },
                maxLines: 1,
                decoration: const InputDecoration(
                  isDense: true, hintText: 'https://www.netflix.com/…',
                  prefixIcon: Icon(Icons.link),
                ),
              )),
              IconButton(
                key: const ValueKey('media-link-paste'),
                tooltip: 'Paste copied link',
                icon: const Icon(Icons.content_paste),
                onPressed: enabled ? _pasteLink : null,
              ),
            ]),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (netflix)
                TextButton(
                  key: const ValueKey('media-link-details'),
                  onPressed: enabled ? () => _sendLink(play: false) : null,
                  child: const Text('Open details'),
                ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('media-link-play'),
                onPressed: enabled ? () => _sendLink(play: true) : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play on computer'),
              ),
            ]),
            if (_linkReady) ...[
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: const ValueKey('media-link-resume'),
                  onPressed: enabled ? () => widget.onKey('Return') : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start / resume if paused'),
                ),
              ),
              Text('Wait for the video player to appear. This uses '
                  'Netflix Play/Pause; it does not reload the link.',
                  style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      const SizedBox(height: 6),
      Text('PLAYBACK', style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant)),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        IconButton(
          key: const ValueKey('media-exit-video'),
          tooltip: 'Back to previous Netflix page',
          icon: const Icon(Icons.arrow_back),
          onPressed: enabled && widget.onExitVideo != null ? _goBack : null,
        ),
        _compact('Rewind 10 seconds', Icons.replay_10,
            netflix ? 'Left' : 'j'),
        _compact('Play or pause', Icons.play_arrow, 'space',
            buttonKey: const ValueKey('media-play-pause'), primary: true),
        _compact('Forward 10 seconds', Icons.forward_10,
            netflix ? 'Right' : 'l'),
        IconButton(
          key: const ValueKey('media-enter-fullscreen'),
          tooltip: 'Enter Netflix video fullscreen',
          icon: const Icon(Icons.fullscreen, size: 23),
          onPressed: enabled ? () => _setFullscreen(true) : null,
        ),
      ]),
      const SizedBox(height: 1),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        IconButton(
          key: const ValueKey('media-exit-fullscreen'),
          tooltip: 'Exit Netflix video fullscreen',
          icon: const Icon(Icons.fullscreen_exit, size: 23),
          onPressed: enabled ? () => _setFullscreen(false) : null,
        ),
        _compact('Player volume down', Icons.volume_down, 'Down',
            buttonKey: const ValueKey('media-volume-down')),
        _compact('Mute or unmute the video player', Icons.volume_off, 'm',
            buttonKey: const ValueKey('media-player-mute')),
        _compact('Player volume up', Icons.volume_up, 'Up',
            buttonKey: const ValueKey('media-volume-up')),
      ]),
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 3),
        child: Text('Player audio · System volume is under More',
          textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
      ),
      ExpansionTile(
        key: const ValueKey('media-more'),
        tilePadding: EdgeInsets.zero,
        leading: const Icon(Icons.tune),
        title: const Text('More video controls'),
        children: [
          Wrap(alignment: WrapAlignment.center,
              spacing: 6, runSpacing: 4, children: [
            if (netflix)
              _button('Skip intro (if supported)', Icons.skip_next, 's')
            else ...[
              _button('Next video', Icons.skip_next, 'shift+n'),
              _button('Captions', Icons.closed_caption, 'c'),
            ],
            _button('System volume -', Icons.volume_down,
                'XF86AudioLowerVolume'),
            _button('System mute', Icons.volume_off,
                'XF86AudioMute'),
            _button('System volume +', Icons.volume_up,
                'XF86AudioRaiseVolume'),
            if (widget.onProfile != null)
              OutlinedButton.icon(
                key: const ValueKey('media-profile'),
                onPressed: enabled ? _chooseProfile : null,
                icon: const Icon(Icons.account_circle_outlined),
                label: Text(netflix ? 'Manage profiles' : 'Open account'),
              ),
            if (widget.onCloseService != null)
              OutlinedButton.icon(
                key: const ValueKey('media-close'),
                onPressed: enabled ? _closeTab : null,
                icon: const Icon(Icons.close),
                label: Text('Close ${widget.service.label} tab'),
              ),
          ]),
        ],
      ),
    ]);
  }
}
