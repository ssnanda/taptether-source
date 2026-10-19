import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// Normalize a user-copied public share URL. Tracking parameters are discarded;
/// arbitrary URLs, credentials, schemes and redirects are never forwarded.
class MediaSharedLink {
  const MediaSharedLink._();
  
  static String destination(MediaService service, String input,
      {required bool play}) {
    final text = input.trim();
    if (text.length > 2048 || text.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const FormatException('Paste a valid Netflix or YouTube share link.');
    }
    final uri = Uri.tryParse(text);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
        uri.hasPort || uri.fragment.isNotEmpty) {
      throw const FormatException('Only HTTPS Netflix/YouTube links are accepted.');
    }
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (service == MediaService.netflix) {
      if (uri.host != 'www.netflix.com' && uri.host != 'netflix.com') {
        throw const FormatException('Paste a Netflix share link.');
      }
      if (parts.length == 3 && RegExp(r'^[a-z]{2}(-[a-z]{2})?
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
  String? _lastSearch;

  @override
  void didUpdateWidget(covariant MediaRemote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service ||
        (oldWidget.enabled && !widget.enabled)) {
      _searchReady = false;
      _search.clear();
      _link.clear();
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
      if (mounted) setState(() => _link.text = raw);
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
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(play ? 'Sent playback link to computer. ' 
              'Your Netflix profile or episode selection may still be needed.'
              : 'Opened title on computer.')));
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
          hintText: _searchReady ? 'Search ' + widget.service.label
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
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 6),
          leading: const Icon(Icons.link),
          title: Text('Play from shared ' + widget.service.label + ' link'),
          subtitle: Text('Copy in ' + widget.service.label +
              ', then paste here', style: theme.textTheme.bodySmall),
          children: [
            Row(children: [
              Expanded(child: TextField(
                key: const ValueKey('media-link-text'),
                controller: _link,
                enabled: enabled,
                autocorrect: false,
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
          ],
        ),
      const SizedBox(height: 6),
      Text('PLAYBACK', style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant)),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        IconButton(
          key: const ValueKey('media-exit-video'),
          tooltip: 'Back to browsing',
          icon: const Icon(Icons.arrow_back),
          onPressed: enabled && widget.onExitVideo != null ? _goBack : null,
        ),
        _compact('Rewind 10 seconds', Icons.replay_10,
            netflix ? 'Left' : 'j'),
        _compact('Play or pause', Icons.play_arrow, 'space',
            buttonKey: const ValueKey('media-play-pause'), primary: true),
        _compact('Forward 10 seconds', Icons.forward_10,
            netflix ? 'Right' : 'l'),
        _compact('Exit full screen', Icons.fullscreen_exit, 'Escape'),
      ]),
      const SizedBox(height: 1),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _compact('Volume down', Icons.volume_down, 'XF86AudioLowerVolume',
            buttonKey: const ValueKey('media-volume-down')),
        const SizedBox(width: 18),
        _compact('Mute or unmute', Icons.volume_off, 'XF86AudioMute'),
        const SizedBox(width: 18),
        _compact('Volume up', Icons.volume_up, 'XF86AudioRaiseVolume',
            buttonKey: const ValueKey('media-volume-up')),
      ]),
      ExpansionTile(
        key: const ValueKey('media-more'),
        tilePadding: EdgeInsets.zero,
        dense: true,
        leading: const Icon(Icons.tune),
        title: const Text('More video controls'),
        children: [
          Wrap(alignment: WrapAlignment.center,
              spacing: 6, runSpacing: 4, children: [
            _button('Full screen', Icons.fullscreen, 'f'),
            if (netflix)
              _button('Skip intro (if supported)', Icons.skip_next, 's')
            else ...[
              _button('Next video', Icons.skip_next, 'shift+n'),
              _button('Captions', Icons.closed_caption, 'c'),
            ],
            if (widget.onProfile != null)
              OutlinedButton.icon(
                key: const ValueKey('media-profile'),
                onPressed: enabled ? _chooseProfile : null,
                icon: const Icon(Icons.account_circle_outlined),
                label: Text(netflix ? 'Choose profile' : 'Switch account'),
              ),
            if (widget.onCloseService != null)
              OutlinedButton.icon(
                key: const ValueKey('media-close'),
                onPressed: enabled ? _closeTab : null,
                icon: const Icon(Icons.close),
                label: Text('Close ' + widget.service.label + ' tab'),
              ),
          ]),
        ],
      ),
    ]);
  }
}
